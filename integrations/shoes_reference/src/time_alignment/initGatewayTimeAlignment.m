function state = initGatewayTimeAlignment(cfg)
% initGatewayTimeAlignment  Initialize left/right gateway clock alignment.

if nargin < 1
    cfg = struct();
end

useTap = getLogicalField(cfg, 'useTap', false);
if useTap
    mode = "tap";
    status = "waiting";
    message = "Place both empty shoes on one rigid board, then start tap alignment.";
else
    mode = "passive";
    status = "collecting";
    message = "Collecting a few seconds of data for automatic gateway time alignment.";
end

state = struct();
state.mode = mode;
state.status = status;
state.ready = false;
state.referenceFoot = "left";
state.rightToLeftOffsetSec = 0;
state.startedArrivalT = NaN;
state.completedArrivalT = NaN;
state.statusMessage = message;
state.observations.left = emptyObservation();
state.observations.right = emptyObservation();
state.result = emptyResult(mode);

end

function observation = emptyObservation()

observation.gatewayT = zeros(0, 1);
observation.arrivalT = zeros(0, 1);
observation.accNormMs2 = zeros(0, 1);

end

function result = emptyResult(method)

result = struct( ...
    'success', false, ...
    'method', string(method), ...
    'rightToLeftOffsetSec', NaN, ...
    'qualitySpreadSec', NaN, ...
    'leftSamples', 0, ...
    'rightSamples', 0, ...
    'pairCount', 0, ...
    'leftArrivalMinusGatewaySec', NaN, ...
    'rightArrivalMinusGatewaySec', NaN, ...
    'leftPeakGatewayT', zeros(0, 1), ...
    'rightPeakGatewayT', zeros(0, 1), ...
    'offsetSamplesSec', zeros(0, 1), ...
    'note', "");

end

function value = getLogicalField(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName))
    value = logical(values.(fieldName));
else
    value = defaultValue;
end

end
