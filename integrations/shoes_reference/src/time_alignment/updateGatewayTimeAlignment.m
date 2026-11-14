function [state, msg, event] = updateGatewayTimeAlignment(state, msg, cfg)
% updateGatewayTimeAlignment  Collect alignment evidence and map one sample.

if nargin < 3
    cfg = struct();
end

event = struct( ...
    'completed', false, ...
    'success', false, ...
    'method', string(state.mode), ...
    'message', "", ...
    'result', state.result);

gatewayT = getScalarField(msg, 'gateway_time_sec', NaN);
arrivalT = getScalarField(msg, 'arrival_time_sec', NaN);
side = char(string(getFieldOr(msg, 'foot', "")));

if ~state.ready && ismember(side, {'left', 'right'}) && ...
        isfinite(gatewayT) && isfinite(arrivalT)
    if state.mode == "passive" && state.status == "collecting"
        state = appendObservation(state, side, gatewayT, arrivalT, NaN, cfg);
        if passiveCaptureComplete(state, cfg)
            result = estimatePassiveGatewayOffset( ...
                state.observations.left, state.observations.right, cfg);
            [state, event] = finishAlignment(state, result, arrivalT);
        end
    elseif state.mode == "tap" && state.status == "collecting" && ...
            strcmp(getFieldOr(msg, 'sensor_type', ''), 'imu')
        accNorm = getImuAccelerationNorm(msg);
        if isfinite(accNorm)
            state = appendObservation( ...
                state, side, gatewayT, arrivalT, accNorm, cfg);
        end
        if tapCaptureComplete(state, cfg)
            result = estimateTapGatewayOffset( ...
                state.observations.left, state.observations.right, cfg);
            [state, event] = finishAlignment(state, result, arrivalT);
        end
    end
end

msg = applyAlignmentToMessage(state, msg);

end

function state = appendObservation(state, side, gatewayT, arrivalT, accNorm, cfg)

observation = state.observations.(side);
observation.gatewayT(end + 1, 1) = gatewayT;
observation.arrivalT(end + 1, 1) = arrivalT;
observation.accNormMs2(end + 1, 1) = accNorm;

maxSamples = round(getNumericField(cfg, 'maxSamplesPerFoot', 3000));
if numel(observation.gatewayT) > maxSamples
    keep = (numel(observation.gatewayT) - maxSamples + 1):numel(observation.gatewayT);
    observation.gatewayT = observation.gatewayT(keep);
    observation.arrivalT = observation.arrivalT(keep);
    observation.accNormMs2 = observation.accNormMs2(keep);
end
state.observations.(side) = observation;

if ~isfinite(state.startedArrivalT)
    state.startedArrivalT = arrivalT;
else
    state.startedArrivalT = min(state.startedArrivalT, arrivalT);
end

end

function complete = passiveCaptureComplete(state, cfg)

durationSec = getNumericField(cfg, 'passiveDurationSec', 5.0);
minimumSamples = round(getNumericField(cfg, 'passiveMinSamplesPerFoot', 100));
left = state.observations.left.arrivalT;
right = state.observations.right.arrivalT;
complete = numel(left) >= minimumSamples && numel(right) >= minimumSamples && ...
    sampleDuration(left) >= durationSec && sampleDuration(right) >= durationSec;

end

function complete = tapCaptureComplete(state, cfg)

durationSec = getNumericField(cfg, 'tapDurationSec', 8.0);
left = state.observations.left.arrivalT;
right = state.observations.right.arrivalT;
if isempty(left) || isempty(right)
    complete = false;
    return;
end
complete = max([left(end), right(end)]) - state.startedArrivalT >= durationSec;

end

function [state, event] = finishAlignment(state, result, completedArrivalT)

state.result = result;
state.completedArrivalT = completedArrivalT;
event.completed = true;
event.success = logical(result.success);
event.method = string(result.method);
event.result = result;
event.message = string(result.note);

if result.success
    state.ready = true;
    state.status = "ready";
    state.rightToLeftOffsetSec = result.rightToLeftOffsetSec;
    state.statusMessage = sprintf( ...
        '%s alignment ready: right clock correction %+0.3f ms.', ...
        char(upperFirst(result.method)), result.rightToLeftOffsetSec * 1000);
else
    state.ready = false;
    state.status = "failed";
    state.statusMessage = string(result.note);
end

end

function msg = applyAlignmentToMessage(state, msg)

gatewayT = getScalarField(msg, 'gateway_time_sec', NaN);
offsetSec = 0;
if state.ready && strcmp(getFieldOr(msg, 'foot', ''), 'right')
    offsetSec = state.rightToLeftOffsetSec;
end
alignedT = gatewayT + offsetSec;

msg.aligned_time_sec = alignedT;
msg.aligned_time_str = formatGatewayTime(alignedT);
msg.time_alignment_method = char(string(state.mode));
msg.time_alignment_ready = logical(state.ready);
msg.time_alignment_offset_sec = offsetSec;

% Existing processing code consumes recv_time_sec. It now explicitly means
% aligned gateway time; callback arrival remains in arrival_time_sec.
msg.recv_time_sec = alignedT;
msg.recv_time_str = msg.aligned_time_str;
msg.sensor_time_sec = alignedT;
if isfield(msg, 't')
    msg.t = alignedT;
end

end

function accNorm = getImuAccelerationNorm(msg)

accNorm = NaN;
if ~isstruct(msg) || ~isfield(msg, 'data')
    return;
end
if isfield(msg.data, 'acc_b_ms2')
    acc = double(msg.data.acc_b_ms2(:));
elseif isfield(msg.data, 'acc_ms2')
    acc = double(msg.data.acc_ms2(:));
else
    return;
end
if numel(acc) >= 3 && all(isfinite(acc(1:3)))
    accNorm = norm(acc(1:3));
end

end

function durationSec = sampleDuration(t)

t = double(t(:));
t = t(isfinite(t));
if numel(t) < 2
    durationSec = 0;
else
    durationSec = max(t) - min(t);
end

end

function text = formatGatewayTime(t)

if ~isfinite(t)
    text = "";
    return;
end
try
    dt = datetime(t, 'ConvertFrom', 'posixtime', ...
        'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
    text = string(dt);
catch
    text = "";
end

end

function value = upperFirst(value)

value = char(string(value));
if ~isempty(value)
    value(1) = upper(value(1));
end
value = string(value);

end

function value = getFieldOr(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName))
    value = values.(fieldName);
else
    value = defaultValue;
end

end

function value = getScalarField(values, fieldName, defaultValue)

value = getFieldOr(values, fieldName, defaultValue);
value = double(value(1));

end

function value = getNumericField(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName)) && isfinite(double(values.(fieldName)(1)))
    value = double(values.(fieldName)(1));
else
    value = defaultValue;
end

end
