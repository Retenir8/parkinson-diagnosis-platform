function [session, event] = updateGaitSessionCalibration(session, msg, cfg)
% updateGaitSessionCalibration  Consume one decoded sensor message.

event = emptyCalibrationEvent();
if isempty(session) || isempty(msg) || ~isfield(msg, 'foot')
    return;
end

side = char(msg.foot);
if ~ismember(side, {'left', 'right'})
    return;
end

switch string(session.phase)
    case "unloaded_calibration"
        [session.unloaded.(side), completedNow] = updateUnloadedCollector( ...
            session.unloaded.(side), msg, cfg);
        if completedNow
            session.calibration.(side) = session.unloaded.(side).result;
            event.completed = true;
            event.stage = "unloaded";
            event.foot = string(side);
            event.result = session.unloaded.(side).result;
        end
        session.unloadedComplete = session.unloaded.left.complete && ...
            session.unloaded.right.complete;
        if session.unloadedComplete
            session.phase = "unloaded_complete";
            session.statusMessage = ...
                "Empty-shoe calibration passed. Put on both shoes, then start standing preparation.";
            event.stageComplete = true;
        end

    case "worn_preparation"
        floorResult = session.calibration.(side);
        [session.worn.(side), completedNow] = updateWornCollector( ...
            session.worn.(side), msg, floorResult, cfg);
        if completedNow
            session.calibration.(side) = mergeCalibrationResults( ...
                floorResult, session.worn.(side).result);
            event.completed = true;
            event.stage = "worn";
            event.foot = string(side);
            event.result = session.calibration.(side);
        end
        session.wornComplete = session.worn.left.complete && ...
            session.worn.right.complete;
        if session.wornComplete
            session.phase = "ready_to_record";
            session.statusMessage = ...
                "Preparation passed. Stand ready, then start analysis and recording.";
            event.stageComplete = true;
        end
end

end

function [collector, completedNow] = updateUnloadedCollector(collector, msg, cfg)

completedNow = false;
if collector.complete
    return;
end

if strcmp(msg.sensor_type, 'pressure')
    P = getPressureValues(msg);
    if isempty(P)
        return;
    end
    activeCount = sum(P > cfg.calib.unloadedPressureActiveThreshold);
    if activeCount >= cfg.calib.unloadedMaxActiveSensors
        collector = resetUnloadedSamples(collector, ...
            "Pressure detected. Remove the foot and avoid touching the shoe.");
        return;
    end
    collector.pressureT(end + 1, 1) = double(msg.recv_time_sec);
    collector.pressure(end + 1, :) = P;
elseif strcmp(msg.sensor_type, 'imu')
    [accBody, q, ok] = getImuCalibrationValues(msg);
    if ~ok
        return;
    end

    t = double(msg.recv_time_sec);
    angularRate = quaternionRateDeg(collector.previousQ, q, ...
        collector.previousImuT, t);
    collector.previousQ = q;
    collector.previousImuT = t;

    if abs(norm(accBody) - cfg.trajectory.gravity) > ...
            cfg.calib.unloadedMaxAccNormError || ...
            angularRate > cfg.calib.unloadedMaxAngularRateDeg
        collector = resetUnloadedSamples(collector, ...
            "Shoe movement detected. Empty-shoe calibration restarted.");
        collector.previousQ = q;
        collector.previousImuT = t;
        return;
    end

    gravityBody = quatRotateVectorWxyz(quatConjWxyz(q), ...
        [0 0 cfg.trajectory.gravity]);
    collector.imuT(end + 1, 1) = t;
    collector.accResidualBody(end + 1, :) = accBody - gravityBody;
    collector.qWxyz(end + 1, :) = q;
    collector.angularRateDeg(end + 1, 1) = angularRate;
end

[collector, completedNow] = finalizeUnloadedIfReady(collector, cfg);

end

function [collector, completedNow] = finalizeUnloadedIfReady(collector, cfg)

completedNow = false;
imuDuration = sampleDuration(collector.imuT);
pressureDuration = sampleDuration(collector.pressureT);
if imuDuration < cfg.calib.unloadedDurationSec || ...
        pressureDuration < cfg.calib.unloadedPressureDurationSec || ...
        numel(collector.imuT) < cfg.calib.unloadedMinImuSamples || ...
        numel(collector.pressureT) < cfg.calib.unloadedMinPressureSamples
    return;
end

accNoise = robustSigma(collector.accResidualBody);
if max(accNoise) > cfg.calib.unloadedMaxAccNoise
    collector = resetUnloadedSamples(collector, ...
        "IMU noise is too high. Empty-shoe calibration restarted.");
    return;
end

result = struct();
result.stage = "unloaded";
result.completedT = max([collector.imuT(end) collector.pressureT(end)]);
result.imuSamples = numel(collector.imuT);
result.pressureSamples = numel(collector.pressureT);
result.durationSec = min(imuDuration, pressureDuration);
result.bodyAccBias = median(collector.accResidualBody, 1);
result.bodyAccNoise = accNoise;
result.qFloorWxyz = averageQuaternionWxyz(collector.qWxyz);
result.angularRateP95Deg = percentileLocal(collector.angularRateDeg, 95);
result.pressureZero = median(collector.pressure, 1);
result.pressureNoise = robustSigma(collector.pressure);
result.standingTotalPressure = NaN;
result.standingCOP = [NaN NaN];
result.q0_wxyz = result.qFloorWxyz;
result.accNavBias = [0 0 0];

collector.result = result;
collector.complete = true;
collector.lastIssue = "";
completedNow = true;

end

function [collector, completedNow] = updateWornCollector(collector, msg, floorResult, cfg)

completedNow = false;
if collector.complete || isempty(fieldnames(floorResult))
    return;
end

if strcmp(msg.sensor_type, 'pressure')
    P = getPressureValues(msg);
    if isempty(P)
        return;
    end
    P = max(P - floorResult.pressureZero, 0);
    region = computePressureRegions48(P, cfg.gait);
    activeCount = sum(P > cfg.calib.wornPressureActiveThreshold);
    contactPresent = activeCount >= cfg.calib.wornMinActiveSensors && ...
        region.total >= cfg.calib.wornMinTotalPressure;
    collector.contactPresent = contactPresent;
    collector.lastPressureT = double(msg.recv_time_sec);

    if ~contactPresent
        collector = resetWornSamples(collector, ...
            "Both feet must remain supported during standing preparation.");
        return;
    end

    collector.pressureT(end + 1, 1) = double(msg.recv_time_sec);
    collector.pressure(end + 1, :) = P;
    collector.totalPressure(end + 1, 1) = region.total;
    collector.cop(end + 1, :) = [region.copXNorm region.copYNorm];
elseif strcmp(msg.sensor_type, 'imu')
    [accBody, q, ok] = getImuCalibrationValues(msg);
    if ~ok || ~collector.contactPresent
        return;
    end

    t = double(msg.recv_time_sec);
    if ~isfinite(collector.lastPressureT) || ...
            abs(t - collector.lastPressureT) > cfg.calib.wornMaxPressureAgeSec
        return;
    end

    angularRate = quaternionRateDeg(collector.previousQ, q, ...
        collector.previousImuT, t);
    collector.previousQ = q;
    collector.previousImuT = t;
    if abs(norm(accBody) - cfg.trajectory.gravity) > ...
            cfg.calib.wornMaxAccNormError || ...
            angularRate > cfg.calib.wornMaxAngularRateDeg
        collector = resetWornSamples(collector, ...
            "Foot movement detected. Standing preparation restarted.");
        collector.previousQ = q;
        collector.previousImuT = t;
        return;
    end

    correctedBody = accBody - floorResult.bodyAccBias;
    accWorldResidual = quatRotateVectorWxyz(q, correctedBody) - ...
        [0 0 cfg.trajectory.gravity];
    collector.imuT(end + 1, 1) = t;
    collector.qWxyz(end + 1, :) = q;
    collector.accWorldResidual(end + 1, :) = accWorldResidual;
    collector.angularRateDeg(end + 1, 1) = angularRate;
end

[collector, completedNow] = finalizeWornIfReady(collector, cfg);

end

function [collector, completedNow] = finalizeWornIfReady(collector, cfg)

completedNow = false;
imuDuration = sampleDuration(collector.imuT);
pressureDuration = sampleDuration(collector.pressureT);
if imuDuration < cfg.calib.wornDurationSec || ...
        pressureDuration < cfg.calib.wornDurationSec || ...
        numel(collector.imuT) < cfg.calib.wornMinImuSamples || ...
        numel(collector.pressureT) < cfg.calib.wornMinPressureSamples
    return;
end

totalMedian = median(collector.totalPressure);
totalRobustSigma = robustSigma(collector.totalPressure);
loadVariation = totalRobustSigma / max(totalMedian, 1e-6);
copNoise = robustSigma(collector.cop);
if loadVariation > cfg.calib.wornMaxLoadVariation || ...
        max(copNoise) > cfg.calib.wornMaxCopNoise
    collector = resetWornSamples(collector, ...
        "Standing pressure is not stable enough. Preparation restarted.");
    return;
end

result = struct();
result.stage = "worn";
result.completedT = max([collector.imuT(end) collector.pressureT(end)]);
result.imuSamples = numel(collector.imuT);
result.pressureSamples = numel(collector.pressureT);
result.durationSec = min(imuDuration, pressureDuration);
result.standingTotalPressure = max(totalMedian, 1e-6);
result.standingCOP = median(collector.cop, 1);
result.q0_wxyz = averageQuaternionWxyz(collector.qWxyz);
result.accNavBias = median(collector.accWorldResidual, 1);
result.accNavNoise = robustSigma(collector.accWorldResidual);
result.angularRateP95Deg = percentileLocal(collector.angularRateDeg, 95);
result.loadVariation = loadVariation;
result.copNoise = copNoise;

collector.result = result;
collector.complete = true;
collector.lastIssue = "";
completedNow = true;

end

function calibration = mergeCalibrationResults(floorResult, wornResult)

calibration = floorResult;
names = fieldnames(wornResult);
for i = 1:numel(names)
    calibration.(names{i}) = wornResult.(names{i});
end
calibration.stage = "ready";

end

function collector = resetUnloadedSamples(collector, issue)

collector.imuT = zeros(0, 1);
collector.accResidualBody = zeros(0, 3);
collector.qWxyz = zeros(0, 4);
collector.angularRateDeg = zeros(0, 1);
collector.pressureT = zeros(0, 1);
collector.pressure = zeros(0, 48);
collector.previousImuT = NaN;
collector.previousQ = [NaN NaN NaN NaN];
collector.lastIssue = string(issue);

end

function collector = resetWornSamples(collector, issue)

collector.imuT = zeros(0, 1);
collector.qWxyz = zeros(0, 4);
collector.accWorldResidual = zeros(0, 3);
collector.angularRateDeg = zeros(0, 1);
collector.pressureT = zeros(0, 1);
collector.pressure = zeros(0, 48);
collector.totalPressure = zeros(0, 1);
collector.cop = zeros(0, 2);
collector.previousImuT = NaN;
collector.previousQ = [NaN NaN NaN NaN];
collector.lastPressureT = NaN;
collector.contactPresent = false;
collector.lastIssue = string(issue);

end

function [accBody, q, ok] = getImuCalibrationValues(msg)

accBody = [NaN NaN NaN];
q = [1 0 0 0];
ok = false;
if ~isfield(msg, 'data') || ~isstruct(msg.data)
    return;
end

if isfield(msg.data, 'acc_ms2') && numel(msg.data.acc_ms2) >= 3
    accBody = double(msg.data.acc_ms2(1:3));
elseif isfield(msg.data, 'acc_g') && numel(msg.data.acc_g) >= 3
    accBody = double(msg.data.acc_g(1:3)) * 9.80665;
end
if isfield(msg.data, 'q_wxyz') && numel(msg.data.q_wxyz) >= 4
    q = double(msg.data.q_wxyz(1:4));
end

accBody = accBody(:).';
q = q(:).';
q = q ./ max(norm(q), 1e-12);
ok = all(isfinite(accBody)) && all(isfinite(q));

end

function P = getPressureValues(msg)

P = [];
if isfield(msg, 'data') && isstruct(msg.data) && ...
        isfield(msg.data, 'values') && numel(msg.data.values) == 48
    P = double(msg.data.values(:).');
    P(~isfinite(P)) = 0;
end

end

function rateDeg = quaternionRateDeg(previousQ, q, previousT, t)

rateDeg = 0;
if ~all(isfinite(previousQ)) || ~isfinite(previousT) || ...
        ~isfinite(t) || t <= previousT
    return;
end

dt = t - previousT;
dotValue = min(1, max(-1, abs(dot(previousQ, q))));
angleDeg = rad2deg(2 * acos(dotValue));
rateDeg = angleDeg / dt;

end

function duration = sampleDuration(t)

if numel(t) < 2
    duration = 0;
else
    duration = max(0, t(end) - t(1));
end

end

function sigma = robustSigma(values)

if isempty(values)
    sigma = NaN(1, size(values, 2));
    return;
end

center = median(values, 1);
sigma = 1.4826 * median(abs(values - center), 1);

end

function value = percentileLocal(values, percentile)

values = sort(values(isfinite(values)));
if isempty(values)
    value = NaN;
    return;
end

index = 1 + (numel(values) - 1) * percentile / 100;
low = floor(index);
high = ceil(index);
if low == high
    value = values(low);
else
    value = values(low) + (index - low) * (values(high) - values(low));
end

end

function event = emptyCalibrationEvent()

event = struct( ...
    'completed', false, ...
    'stageComplete', false, ...
    'stage', "", ...
    'foot', "", ...
    'result', struct());

end
