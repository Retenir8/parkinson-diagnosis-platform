function estimator = updateTrajectoryEstimator(estimator, sample, cfg)
% updateTrajectoryEstimator  Integrate IMU acceleration during swing.
%
% Pressure hysteresis determines contact.  During contact the corresponding
% foot is assumed stationary: velocity is zeroed and position is held.

if nargin < 1 || isempty(estimator)
    estimator = initTrajectoryEstimator();
end

if nargin < 3 || isempty(cfg)
    if isfield(estimator, 'cfg')
        cfg = estimator.cfg;
    else
        cfg = struct();
    end
end

cfg = fillTrajectoryDefaults(cfg);
estimator.cfg = cfg;

estimator.left = updateOneFoot(estimator.left, getFootSample(sample, 'left'), cfg, 'left');
estimator.right = updateOneFoot(estimator.right, getFootSample(sample, 'right'), cfg, 'right');
estimator.lastUpdateT = getSampleTime(sample);

end

function s = updateOneFoot(s, footSample, cfg, side)

s = ensureOneFootFields(s);
s.stepEvent = false;
s.maxReasonableStepLength = cfg.maxReasonableStepLength;
s.maxSwingDurationMsFallback = cfg.maxSwingDurationMs;

if isempty(footSample)
    return;
end

t = getFootTime(footSample);
if ~isfinite(t)
    return;
end

s = applyCalibrationReference(s, footSample, cfg, side);

[totalPressure, hasPressure, activeSensorCount, hasActiveSensorCount] = ...
    getPressureFeatures(footSample, cfg);
if hasPressure
    s.totalPressure = totalPressure;
end
if hasActiveSensorCount
    s.activeSensorCount = activeSensorCount;
end

standingTotal = getStandingTotalPressure(footSample);
if isfinite(standingTotal) && standingTotal > 0
    s.standingTotalPressure = standingTotal;
elseif ~isfinite(s.standingTotalPressure) && hasPressure && s.contact && totalPressure > 0
    s.standingTotalPressure = totalPressure;
end

if hasPressure
    s.lastContact = s.contact;
    s = updateContactState(s, totalPressure, s.standingTotalPressure, ...
        activeSensorCount, hasActiveSensorCount, t, cfg);
    s = seedInitialLandingAnchor(s, t, totalPressure, cfg);
    if s.contact && ~s.lastContact
        s = applyLandingVelocityCorrection(s, t, cfg);
        s = registerLandingStep(s, t);
        s = resetInertialBoundaryAtContactChange(s, t, cfg);
    elseif ~s.contact && s.lastContact
        s = seedFirstStepAnchorAtToeOff(s, t);
        s = resetInertialBoundaryAtContactChange(s, t, cfg);
        s = beginSwingHistory(s, t);
    end
end

if ~isfield(footSample, 'imu') || isempty(footSample.imu)
    if s.contact
        s.zuptActive = true;
        s.vel = [0 0 0];
        s.accWorld = [0 0 0];
        s.lastAccWorld = [0 0 0];
        if cfg.lockVerticalOnContact
            s.pos(3) = cfg.groundZ;
        end
        s.displayPos = s.pos;
    else
        s.zuptActive = false;
    end
    return;
end

imuData = getImuData(footSample.imu);
[accBody, okAcc] = getAccBodyMps2(imuData, cfg);
if ~okAcc
    return;
end

q = getQuatWxyz(imuData);

accWorldRaw = removeGravityAndRotateToWorld(q, accBody - s.bodyAccBias, cfg);
[accWorldRaw, q] = alignWorldHeading(accWorldRaw, q, s);
s.lastQuatWxyz = q;
s.accWorldRaw = accWorldRaw;

if isempty(s.lastT)
    s.lastT = t;
    s.vel = [0 0 0];
    s.zuptActive = s.contact;
    s.lastAccWorld = [0 0 0];
    return;
end

dt = t - s.lastT;
s.lastT = t;
s.lastDt = dt;
s.dtSkipped = false;

if ~isfinite(dt) || dt <= 0
    s.dtSkipped = true;
    if s.contact
        s.vel = [0 0 0];
    end
    return;
end

dt = max(min(dt, cfg.maxDt), cfg.minDt);

if s.contact
    s.zuptActive = true;
    s.vel = [0 0 0];
    if cfg.lockVerticalOnContact
        s.pos(3) = cfg.groundZ;
    end
    s.displayPos = s.pos;
    if all(isfinite(accWorldRaw))
        s.accBias = (1 - cfg.biasAdaptGain) * s.accBias + cfg.biasAdaptGain * accWorldRaw;
    end
    s.accWorld = [0 0 0];
    s.lastAccWorld = [0 0 0];
    return;
end

s.zuptActive = false;
accWorld = accWorldRaw - s.accBias;
if ~cfg.useVertical
    accWorld(3) = 0;
else
    accWorld(3) = accWorld(3) - s.swingVerticalBias;
end

accNorm = norm(accWorld);
if isfinite(accNorm) && accNorm < cfg.accDeadband
    accWorld = [0 0 0];
end

oldVel = s.vel;
accForVelocity = 0.5 * (s.lastAccWorld + accWorld);
s.vel = s.vel + accForVelocity * dt;

speed = norm(s.vel);
if isfinite(speed) && speed > cfg.maxSpeed
    s.vel = s.vel / speed * cfg.maxSpeed;
end

s.pos = s.pos + 0.5 * (oldVel + s.vel) * dt;
s.accWorld = accWorld;
s.lastAccWorld = accWorld;
s = appendSwingHistory(s, t, cfg);
s.displayPos = makeProvisionalDisplayPosition(s.pos, cfg);

end

function s = applyLandingVelocityCorrection(s, t, cfg)

s.rawLandingPos = s.pos;
s.preZuptVelocity = s.vel;
s.lastLandingCorrection = [0 0 0];

if all(isfinite(s.lastLandingPos))
    rawDelta = s.rawLandingPos - s.lastLandingPos;
    s.rawStepLength = norm(rawDelta(1:2));
else
    s.rawStepLength = NaN;
end

swingDuration = getDurationOrNaN(s.swingStartT, t);
if ~isfinite(swingDuration) || swingDuration <= 0 || ...
        ~isfinite(cfg.landingVelocityCorrectionGain) || ...
        ~all(isfinite(s.vel))
    return;
end

s = updateVerticalSwingBias(s, swingDuration, cfg);

correction = -0.5 * cfg.landingVelocityCorrectionGain * swingDuration * s.vel;
if cfg.lockVerticalOnContact
    correction(3) = cfg.groundZ - s.rawLandingPos(3);
end

horizontalNorm = norm(correction(1:2));
if isfinite(cfg.maxLandingCorrection) && cfg.maxLandingCorrection > 0 && ...
        horizontalNorm > cfg.maxLandingCorrection
    correction(1:2) = correction(1:2) * cfg.maxLandingCorrection / horizontalNorm;
end

s.pos = s.pos + correction;
s.lastLandingCorrection = correction;
if cfg.lockVerticalOnContact
    s.pos(3) = cfg.groundZ;
end
s.displayPos = s.pos;
s = finalizeSwingHistory(s, t, correction, cfg);

end

function s = updateVerticalSwingBias(s, swingDuration, cfg)

s.lastVerticalSwingBiasResidual = NaN;
if ~cfg.useVertical || ~isfinite(swingDuration) || ...
        swingDuration < cfg.verticalBiasMinSwingDuration || ...
        swingDuration > cfg.verticalBiasMaxSwingDuration || ...
        ~all(isfinite([s.rawLandingPos(3) s.preZuptVelocity(3)]))
    return;
end

heightError = s.rawLandingPos(3) - cfg.groundZ;
residualFromVelocity = s.preZuptVelocity(3) / swingDuration;
residualFromHeight = 2 * heightError / (swingDuration ^ 2);
residual = 0.5 * (residualFromVelocity + residualFromHeight);
residual = max(-cfg.maxVerticalBiasResidual, ...
    min(cfg.maxVerticalBiasResidual, residual));

s.lastVerticalSwingBiasResidual = residual;
s.swingVerticalBias = s.swingVerticalBias + ...
    cfg.verticalSwingBiasAdaptGain * residual;
s.swingVerticalBias = max(-cfg.maxVerticalSwingBias, ...
    min(cfg.maxVerticalSwingBias, s.swingVerticalBias));

end

function s = beginSwingHistory(s, t)

s.swingHistoryT = t;
s.swingHistoryPos = s.pos;
s.swingHistoryVel = s.vel;
s.lastCorrectedSwingT = zeros(0, 1);
s.lastCorrectedSwingPos = zeros(0, 3);
s.lastCorrectedSwingVel = zeros(0, 3);
s.lastRawSwingT = zeros(0, 1);
s.lastRawSwingPos = zeros(0, 3);
s.lastRawSwingVel = zeros(0, 3);

end

function s = appendSwingHistory(s, t, cfg)

if s.contact || ~isfinite(t)
    return;
end

s.swingHistoryT(end + 1, 1) = t;
s.swingHistoryPos(end + 1, :) = s.pos;
s.swingHistoryVel(end + 1, :) = s.vel;

maxSamples = max(2, round(cfg.maxSwingHistorySamples));
if numel(s.swingHistoryT) > maxSamples
    keep = numel(s.swingHistoryT) - maxSamples + 1:numel(s.swingHistoryT);
    s.swingHistoryT = s.swingHistoryT(keep);
    s.swingHistoryPos = s.swingHistoryPos(keep, :);
    s.swingHistoryVel = s.swingHistoryVel(keep, :);
end

end

function s = finalizeSwingHistory(s, landingT, endpointCorrection, cfg)

if isempty(s.swingHistoryT) || ~isfinite(s.swingStartT) || ...
        ~isfinite(landingT) || landingT <= s.swingStartT
    s.lastCorrectedSwingT = zeros(0, 1);
    s.lastCorrectedSwingPos = zeros(0, 3);
    s.lastCorrectedSwingVel = zeros(0, 3);
    s.lastRawSwingT = zeros(0, 1);
    s.lastRawSwingPos = zeros(0, 3);
    s.lastRawSwingVel = zeros(0, 3);
    return;
end

t = s.swingHistoryT;
rawPos = s.swingHistoryPos;
rawVel = s.swingHistoryVel;
if t(end) < landingT
    t(end + 1, 1) = landingT;
    rawPos(end + 1, :) = s.rawLandingPos;
    rawVel(end + 1, :) = s.preZuptVelocity;
end

swingDuration = landingT - s.swingStartT;
alpha = max(0, min(1, (t - s.swingStartT) / swingDuration));
velocityCorrection = -s.preZuptVelocity;
% Cubic drift correction preserves the toe-off boundary and enforces the
% corrected landing position and zero terminal velocity.
coefA = 3 * endpointCorrection - velocityCorrection * swingDuration;
coefB = velocityCorrection * swingDuration - 2 * endpointCorrection;

positionCorrection = alpha .^ 2 * coefA + alpha .^ 3 * coefB;
velocityCorrectionSeries = ...
    (2 * alpha / swingDuration) * coefA + ...
    (3 * alpha .^ 2 / swingDuration) * coefB;

correctedPos = rawPos + positionCorrection;
correctedVel = rawVel + velocityCorrectionSeries;
if cfg.lockVerticalOnContact
    verticalFloor = cfg.groundZ - cfg.verticalFloorTolerance;
    verticalCeiling = cfg.groundZ + cfg.maxCorrectedVerticalExcursion;
    correctedPos(:, 3) = min(max(correctedPos(:, 3), verticalFloor), verticalCeiling);
    correctedPos(end, 3) = cfg.groundZ;
    correctedVel(end, 3) = 0;
end

s.lastCorrectedSwingT = t;
s.lastCorrectedSwingPos = correctedPos;
s.lastCorrectedSwingVel = correctedVel;
s.lastRawSwingT = t;
s.lastRawSwingPos = rawPos;
s.lastRawSwingVel = rawVel;
s.swingHistoryT = zeros(0, 1);
s.swingHistoryPos = zeros(0, 3);
s.swingHistoryVel = zeros(0, 3);

end

function pos = makeProvisionalDisplayPosition(rawPos, cfg)

pos = rawPos;
if ~cfg.useVertical
    pos(3) = cfg.groundZ;
    return;
end

verticalFloor = cfg.groundZ - cfg.provisionalVerticalFloorTolerance;
verticalCeiling = cfg.groundZ + cfg.maxProvisionalVerticalExcursion;
pos(3) = min(max(pos(3), verticalFloor), verticalCeiling);

end

function s = registerLandingStep(s, t)

s.stepEvent = true;
s.stepCount = s.stepCount + 1;
s.lastSwingDuration = getDurationOrNaN(s.swingStartT, t);
s.longSwingWarning = isfinite(s.lastSwingDuration) && ...
    s.lastSwingDuration > getSeconds(s, 'maxSwingDurationMsFallback', 1.5);

if all(isfinite(s.lastLandingPos)) && isfinite(s.lastLandingT) && t > s.lastLandingT
    stepDt = t - s.lastLandingT;
    delta = s.pos - s.lastLandingPos;
    s.stepLength = norm(delta(1:2));
    s.stepCadence = 60 / stepDt;
    s.stepSpeed = s.stepLength / stepDt;
    s.suspiciousStep = s.stepLength > s.maxReasonableStepLength || s.longSwingWarning;
else
    s.stepLength = NaN;
    s.stepCadence = NaN;
    s.stepSpeed = NaN;
    s.suspiciousStep = false;
end

s.missedLandingSuspected = s.longSwingWarning;
s.lastLandingT = t;
s.lastLandingPos = s.pos;

end

function s = seedInitialLandingAnchor(s, t, totalPressure, cfg)

if s.initialLandingAnchored || ~s.contact || ~isfinite(t) || ...
        ~isPressureConfirmedContact(s, totalPressure, cfg)
    return;
end

s.initialLandingAnchored = true;
s.lastLandingT = t;
s.lastLandingPos = s.pos;
if ~isfinite(s.stanceStartT)
    s.stanceStartT = t;
end

end

function s = seedFirstStepAnchorAtToeOff(s, t)

if s.stepCount ~= 0 || ~isfinite(t)
    return;
end

s.initialLandingAnchored = true;
s.lastLandingT = t;
s.lastLandingPos = s.pos;

end

function s = resetInertialBoundaryAtContactChange(s, t, cfg)

if isfinite(t)
    s.lastT = t;
end

s.lastAccWorld = [0 0 0];
s.accWorld = [0 0 0];

if s.contact
    s.zuptActive = true;
    s.vel = [0 0 0];
    if cfg.lockVerticalOnContact
        s.pos(3) = cfg.groundZ;
    end
else
    s.zuptActive = false;
end
s.displayPos = s.pos;

end

function ok = isPressureConfirmedContact(s, totalPressure, cfg)

ok = false;
if ~isfinite(totalPressure)
    return;
end

if isfinite(s.standingTotalPressure) && s.standingTotalPressure > 0
    pressureSignal = totalPressure / max(s.standingTotalPressure, 1e-6);
    ok = pressureSignal > cfg.pressureOffThreshold;
else
    ok = totalPressure > cfg.pressureOff;
end

end

function s = ensureOneFootFields(s)

if ~isfield(s, 'lastAccWorld')
    s.lastAccWorld = [0 0 0];
end
if ~isfield(s, 'lastContact')
    s.lastContact = true;
end
if ~isfield(s, 'activeSensorCount')
    s.activeSensorCount = 0;
end
if ~isfield(s, 'accBias')
    s.accBias = [0 0 0];
end
if ~isfield(s, 'calibrationAccBiasInitialized')
    s.calibrationAccBiasInitialized = false;
end
if ~isfield(s, 'bodyAccBias')
    s.bodyAccBias = [0 0 0];
end
if ~isfield(s, 'bodyAccBiasInitialized')
    s.bodyAccBiasInitialized = false;
end
if ~isfield(s, 'swingVerticalBias')
    s.swingVerticalBias = 0;
end
if ~isfield(s, 'lastVerticalSwingBiasResidual')
    s.lastVerticalSwingBiasResidual = NaN;
end
if ~isfield(s, 'pos')
    s.pos = [0 0 0];
end
if ~isfield(s, 'displayPos')
    s.displayPos = s.pos;
end
if ~isfield(s, 'vel')
    s.vel = [0 0 0];
end
if ~isfield(s, 'stepEvent')
    s.stepEvent = false;
end
if ~isfield(s, 'stepCount')
    s.stepCount = 0;
end
if ~isfield(s, 'initialLandingAnchored')
    s.initialLandingAnchored = false;
end
if ~isfield(s, 'lastLandingT')
    s.lastLandingT = NaN;
end
if ~isfield(s, 'lastLandingPos')
    s.lastLandingPos = [NaN NaN NaN];
end
if ~isfield(s, 'stepLength')
    s.stepLength = NaN;
end
if ~isfield(s, 'rawLandingPos')
    s.rawLandingPos = [NaN NaN NaN];
end
if ~isfield(s, 'rawStepLength')
    s.rawStepLength = NaN;
end
if ~isfield(s, 'preZuptVelocity')
    s.preZuptVelocity = [NaN NaN NaN];
end
if ~isfield(s, 'lastLandingCorrection')
    s.lastLandingCorrection = [0 0 0];
end
if ~isfield(s, 'swingHistoryT')
    s.swingHistoryT = zeros(0, 1);
end
if ~isfield(s, 'swingHistoryPos')
    s.swingHistoryPos = zeros(0, 3);
end
if ~isfield(s, 'swingHistoryVel')
    s.swingHistoryVel = zeros(0, 3);
end
if ~isfield(s, 'lastCorrectedSwingT')
    s.lastCorrectedSwingT = zeros(0, 1);
end
if ~isfield(s, 'lastCorrectedSwingPos')
    s.lastCorrectedSwingPos = zeros(0, 3);
end
if ~isfield(s, 'lastCorrectedSwingVel')
    s.lastCorrectedSwingVel = zeros(0, 3);
end
if ~isfield(s, 'lastRawSwingT')
    s.lastRawSwingT = zeros(0, 1);
end
if ~isfield(s, 'lastRawSwingPos')
    s.lastRawSwingPos = zeros(0, 3);
end
if ~isfield(s, 'lastRawSwingVel')
    s.lastRawSwingVel = zeros(0, 3);
end
if ~isfield(s, 'referenceYawRad')
    s.referenceYawRad = NaN;
end
if ~isfield(s, 'headingOffsetRad')
    s.headingOffsetRad = 0;
end
if ~isfield(s, 'stepCadence')
    s.stepCadence = NaN;
end
if ~isfield(s, 'stepSpeed')
    s.stepSpeed = NaN;
end
if ~isfield(s, 'pendingContact')
    s.pendingContact = s.contact;
end
if ~isfield(s, 'pendingContactStartT')
    s.pendingContactStartT = NaN;
end
if ~isfield(s, 'stanceStartT')
    s.stanceStartT = NaN;
end
if ~isfield(s, 'swingStartT')
    s.swingStartT = NaN;
end
if ~isfield(s, 'lastStanceDuration')
    s.lastStanceDuration = NaN;
end
if ~isfield(s, 'lastSwingDuration')
    s.lastSwingDuration = NaN;
end
if ~isfield(s, 'suspiciousStep')
    s.suspiciousStep = false;
end
if ~isfield(s, 'longSwingWarning')
    s.longSwingWarning = false;
end
if ~isfield(s, 'missedLandingSuspected')
    s.missedLandingSuspected = false;
end
if ~isfield(s, 'maxReasonableStepLength')
    s.maxReasonableStepLength = 1.5;
end
if ~isfield(s, 'maxSwingDurationMsFallback')
    s.maxSwingDurationMsFallback = 1500;
end

end

function footSample = getFootSample(sample, side)

footSample = [];
if isstruct(sample) && isfield(sample, side)
    footSample = sample.(side);
end

end

function t = getFootTime(footSample)

t = NaN;
if isfield(footSample, 't')
    t = double(footSample.t);
elseif isfield(footSample, 'pressure') && isfield(footSample.pressure, 'recv_time_sec')
    t = double(footSample.pressure.recv_time_sec);
elseif isfield(footSample, 'imu') && isfield(footSample.imu, 'recv_time_sec')
    t = double(footSample.imu.recv_time_sec);
end

end

function t = getSampleTime(sample)

t = NaN;
if isstruct(sample) && isfield(sample, 't')
    t = double(sample.t);
end

end

function [totalPressure, ok, activeSensorCount, hasActiveSensorCount] = ...
        getPressureFeatures(footSample, cfg)

ok = false;
totalPressure = NaN;
activeSensorCount = NaN;
hasActiveSensorCount = false;

if ~isfield(footSample, 'pressure') || isempty(footSample.pressure)
    return;
end

pressure = footSample.pressure;
if isfield(pressure, 'data') && isfield(pressure.data, 'sum')
    totalPressure = double(pressure.data.sum);
    ok = true;
elseif isfield(pressure, 'data') && isfield(pressure.data, 'values')
    values = double(pressure.data.values(:));
    values = values(isfinite(values) & values > 0);
    totalPressure = sum(values);
    ok = true;
elseif isfield(pressure, 'values')
    values = double(pressure.values(:));
    values = values(isfinite(values) & values > 0);
    totalPressure = sum(values);
    ok = true;
end

values = [];
if isfield(pressure, 'data') && isfield(pressure.data, 'values')
    values = double(pressure.data.values(:));
elseif isfield(pressure, 'values')
    values = double(pressure.values(:));
end

if ~isempty(values)
    values(~isfinite(values)) = 0;
    activeSensorCount = sum(values > cfg.activePressureThreshold);
    hasActiveSensorCount = true;
end

end

function standingTotal = getStandingTotalPressure(footSample)

standingTotal = NaN;
if isfield(footSample, 'calib') && isstruct(footSample.calib) && ...
        isfield(footSample.calib, 'standingTotalPressure')
    standingTotal = double(footSample.calib.standingTotalPressure);
end

end

function s = updateContactState(s, totalPressure, standingTotal, ...
        activeSensorCount, hasActiveSensorCount, t, cfg)

contact = s.contact;

if isfinite(standingTotal) && standingTotal > 0
    loadIndex = totalPressure / max(standingTotal, 1e-6);
    pressureSignal = loadIndex;
    onThreshold = cfg.pressureOnThreshold;
    offThreshold = cfg.pressureOffThreshold;
else
    loadIndex = totalPressure;
    pressureSignal = totalPressure;
    onThreshold = cfg.pressureOn;
    offThreshold = cfg.pressureOff;
end

useActiveSensors = cfg.activeSensorContactEnable && hasActiveSensorCount && ...
    isfinite(activeSensorCount);
if contact && useActiveSensors
    rawContact = pressureSignal > offThreshold && ...
        activeSensorCount >= cfg.activeSensorsOff;
elseif ~contact && useActiveSensors
    rawContact = pressureSignal > onThreshold || ...
        activeSensorCount >= cfg.activeSensorsOn;
elseif contact
    rawContact = pressureSignal > offThreshold;
else
    rawContact = pressureSignal > onThreshold;
end

if rawContact ~= s.pendingContact
    s.pendingContact = rawContact;
    s.pendingContactStartT = t;
end

if isnan(s.pendingContactStartT)
    s.pendingContactStartT = t;
end

candidateDuration = t - s.pendingContactStartT;
if s.pendingContact ~= contact && candidateDuration >= cfg.debounceMs / 1000
    if s.pendingContact
        swingDuration = getDurationOrNaN(s.swingStartT, t);
        if ~isfinite(swingDuration) || swingDuration >= cfg.minSwingDurationMs / 1000
            contact = true;
            s.stanceStartT = t;
            s.lastSwingDuration = swingDuration;
        end
    else
        stanceDuration = getDurationOrNaN(s.stanceStartT, t);
        if ~isfinite(stanceDuration) || stanceDuration >= cfg.minStanceDurationMs / 1000
            contact = false;
            s.swingStartT = t;
            s.lastStanceDuration = stanceDuration;
        end
    end
end

if ~contact && isfinite(s.swingStartT)
    swingDurationNow = t - s.swingStartT;
    if swingDurationNow > cfg.maxSwingDurationMs / 1000 && pressureSignal > offThreshold
        contact = true;
        s.stanceStartT = t;
        s.lastSwingDuration = swingDurationNow;
        s.longSwingWarning = true;
        s.missedLandingSuspected = true;
    end
end

s.contact = contact;
s.loadIndex = loadIndex;

end

function s = applyCalibrationReference(s, footSample, cfg, side)

if ~isfield(footSample, 'calib') || ~isstruct(footSample.calib)
    return;
end

calib = footSample.calib;
if ~s.bodyAccBiasInitialized && isfield(calib, 'bodyAccBias') && ...
        numel(calib.bodyAccBias) >= 3
    bodyAccBias = double(calib.bodyAccBias(1:3));
    if all(isfinite(bodyAccBias))
        s.bodyAccBias = bodyAccBias(:).';
        s.bodyAccBiasInitialized = true;
    end
end

if ~s.calibrationAccBiasInitialized && isfield(calib, 'accNavBias') && ...
        numel(calib.accNavBias) >= 3
    accNavBias = double(calib.accNavBias(1:3));
    if all(isfinite(accNavBias))
        s.accBias = accNavBias(:).';
        s.calibrationAccBiasInitialized = true;
    end
end

if ~cfg.alignHeadingToCalibration || isfinite(s.referenceYawRad) || ...
        ~isfield(calib, 'q0_wxyz')
    return;
end

q0 = double(calib.q0_wxyz(:).');
if numel(q0) < 4 || ~all(isfinite(q0(1:4)))
    return;
end

q0 = q0(1:4);
q0 = q0 ./ max(norm(q0), 1e-12);
s.referenceYawRad = quaternionYawWxyz(q0);
s.headingOffsetRad = deg2rad(getHeadingOffsetDeg(cfg, side));

alignmentAngle = -s.referenceYawRad + s.headingOffsetRad;
s.pos = rotateVectorAboutZ(s.pos, alignmentAngle);
s.displayPos = rotateVectorAboutZ(s.displayPos, alignmentAngle);
s.vel = rotateVectorAboutZ(s.vel, alignmentAngle);
s.accBias = rotateVectorAboutZ(s.accBias, alignmentAngle);
s.accWorld = rotateVectorAboutZ(s.accWorld, alignmentAngle);
s.accWorldRaw = rotateVectorAboutZ(s.accWorldRaw, alignmentAngle);
s.lastAccWorld = rotateVectorAboutZ(s.lastAccWorld, alignmentAngle);

end

function [accWorld, qAligned] = alignWorldHeading(accWorld, q, s)

qAligned = q;
if ~isfinite(s.referenceYawRad)
    return;
end

alignmentAngle = -s.referenceYawRad + s.headingOffsetRad;
accWorld = rotateVectorAboutZ(accWorld, alignmentAngle);
qYaw = [cos(alignmentAngle / 2) 0 0 sin(alignmentAngle / 2)];
qAligned = quatMultiplyWxyz(qYaw, q);
qAligned = qAligned ./ max(norm(qAligned), 1e-12);

end

function offsetDeg = getHeadingOffsetDeg(cfg, side)

offsetDeg = 0;
if ~isfield(cfg, 'headingOffsetDeg')
    return;
end

value = cfg.headingOffsetDeg;
if isstruct(value) && isfield(value, side)
    value = value.(side);
end

if isnumeric(value) && isscalar(value) && isfinite(value)
    offsetDeg = double(value);
end

end

function yaw = quaternionYawWxyz(q)

w = q(1);
x = q(2);
y = q(3);
z = q(4);
yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));

end

function vRot = rotateVectorAboutZ(v, angle)

v = double(v(:).');
if numel(v) < 3
    v = [v zeros(1, 3 - numel(v))];
end

c = cos(angle);
s = sin(angle);
vRot = [c * v(1) - s * v(2), s * v(1) + c * v(2), v(3)];

end

function q = quatMultiplyWxyz(a, b)

aw = a(1); ax = a(2); ay = a(3); az = a(4);
bw = b(1); bx = b(2); by = b(3); bz = b(4);
q = [ ...
    aw * bw - ax * bx - ay * by - az * bz, ...
    aw * bx + ax * bw + ay * bz - az * by, ...
    aw * by - ax * bz + ay * bw + az * bx, ...
    aw * bz + ax * by - ay * bx + az * bw];

end

function duration = getDurationOrNaN(t0, t1)

if isfinite(t0) && isfinite(t1) && t1 >= t0
    duration = t1 - t0;
else
    duration = NaN;
end

end

function seconds = getSeconds(s, fieldName, defaultValue)

if isfield(s, fieldName) && isfinite(double(s.(fieldName)))
    seconds = double(s.(fieldName)) / 1000;
else
    seconds = defaultValue;
end

end

function imuData = getImuData(imuMsg)

if isstruct(imuMsg) && isfield(imuMsg, 'data')
    imuData = imuMsg.data;
else
    imuData = imuMsg;
end

end

function [accBody, ok] = getAccBodyMps2(imuData, cfg)

ok = false;
accBody = [NaN NaN NaN];

accUnit = string(cfg.accUnit);

if accUnit == "mps2" && isstruct(imuData) && isfield(imuData, 'acc_ms2') && numel(imuData.acc_ms2) >= 3
    accBody = double(imuData.acc_ms2(1:3));
    ok = true;
elseif isstruct(imuData) && isfield(imuData, 'acc_g') && numel(imuData.acc_g) >= 3
    accBody = double(imuData.acc_g(1:3)) * cfg.gravity;
    ok = true;
elseif isstruct(imuData) && isfield(imuData, 'acc_ms2') && numel(imuData.acc_ms2) >= 3
    accBody = double(imuData.acc_ms2(1:3));
    ok = true;
end

accBody = accBody(:).';
ok = ok && all(isfinite(accBody));

end

function q = getQuatWxyz(imuData)

if isstruct(imuData) && isfield(imuData, 'q_wxyz') && numel(imuData.q_wxyz) >= 4
    q = double(imuData.q_wxyz(1:4));
else
    q = [1 0 0 0];
end

q = q(:).';
q = q ./ max(norm(q), 1e-12);

end

function accWorld = removeGravityAndRotateToWorld(q, accBody, cfg)

gravityWorld = [0 0 cfg.gravity];

if string(cfg.quatDirection) == "worldToBody"
    bodyToWorldQ = quatConjWxyz(q);
    worldToBodyQ = q;
else
    bodyToWorldQ = q;
    worldToBodyQ = quatConjWxyz(q);
end

if string(cfg.gravityRemovalMode) == "worldAfterRotation"
    accWorld = quatRotateVectorWxyz(bodyToWorldQ, accBody) - gravityWorld;
else
    % xIMU-style flow: express gravity in the sensor frame, subtract it
    % there, then rotate the remaining linear acceleration into world axes.
    gravityBody = quatRotateVectorWxyz(worldToBodyQ, gravityWorld);
    linAccBody = accBody - gravityBody;
    accWorld = quatRotateVectorWxyz(bodyToWorldQ, linAccBody);
end

end

function cfg = fillTrajectoryDefaults(cfg)

if ~isfield(cfg, 'gravity')
    cfg.gravity = 9.80665;
end
if ~isfield(cfg, 'contactOn')
    cfg.contactOn = 0.20;
end
if ~isfield(cfg, 'contactOff')
    cfg.contactOff = 0.10;
end
if ~isfield(cfg, 'pressureOn')
    cfg.pressureOn = 300;
end
if ~isfield(cfg, 'pressureOff')
    cfg.pressureOff = 150;
end
if ~isfield(cfg, 'maxDt')
    cfg.maxDt = 0.15;
end
if ~isfield(cfg, 'minDt')
    cfg.minDt = 1e-4;
end
if ~isfield(cfg, 'biasAdaptGain')
    cfg.biasAdaptGain = 0.01;
end
if ~isfield(cfg, 'maxSpeed')
    cfg.maxSpeed = 4.0;
end
if ~isfield(cfg, 'quatDirection')
    cfg.quatDirection = "bodyToWorld";
end
if ~isfield(cfg, 'useVertical')
    cfg.useVertical = true;
end
if ~isfield(cfg, 'lockVerticalOnContact')
    cfg.lockVerticalOnContact = true;
end
if ~isfield(cfg, 'groundZ')
    cfg.groundZ = 0;
end
if ~isfield(cfg, 'accDeadband')
    cfg.accDeadband = 0.15;
end
if ~isfield(cfg, 'gravityRemovalMode')
    cfg.gravityRemovalMode = "bodyThenWorld";
end
if ~isfield(cfg, 'pressureOnThreshold')
    cfg.pressureOnThreshold = cfg.contactOn;
end
if ~isfield(cfg, 'pressureOffThreshold')
    cfg.pressureOffThreshold = cfg.contactOff;
end
if ~isfield(cfg, 'minStanceDurationMs')
    cfg.minStanceDurationMs = 30;
end
if ~isfield(cfg, 'minSwingDurationMs')
    cfg.minSwingDurationMs = 30;
end
if ~isfield(cfg, 'debounceMs')
    cfg.debounceMs = 20;
end
if ~isfield(cfg, 'maxSwingDurationMs')
    cfg.maxSwingDurationMs = 1500;
end
if ~isfield(cfg, 'useHeelToToeAsRequired')
    cfg.useHeelToToeAsRequired = false;
end
if ~isfield(cfg, 'maxReasonableStepLength')
    cfg.maxReasonableStepLength = 1.5;
end
if ~isfield(cfg, 'accUnit')
    cfg.accUnit = "g";
end
if ~isfield(cfg, 'activeSensorContactEnable')
    cfg.activeSensorContactEnable = false;
end
if ~isfield(cfg, 'activePressureThreshold')
    cfg.activePressureThreshold = 200;
end
if ~isfield(cfg, 'activeSensorsOn')
    cfg.activeSensorsOn = 4;
end
if ~isfield(cfg, 'activeSensorsOff')
    cfg.activeSensorsOff = 3;
end
if ~isfield(cfg, 'landingVelocityCorrectionGain')
    cfg.landingVelocityCorrectionGain = 0;
end
if ~isfield(cfg, 'maxLandingCorrection')
    cfg.maxLandingCorrection = 2.0;
end
if ~isfield(cfg, 'alignHeadingToCalibration')
    cfg.alignHeadingToCalibration = false;
end
if ~isfield(cfg, 'headingOffsetDeg')
    cfg.headingOffsetDeg = struct('left', 0, 'right', 0);
end
if ~isfield(cfg, 'verticalFloorTolerance')
    cfg.verticalFloorTolerance = 0.02;
end
if ~isfield(cfg, 'maxCorrectedVerticalExcursion')
    cfg.maxCorrectedVerticalExcursion = 0.35;
end
if ~isfield(cfg, 'provisionalVerticalFloorTolerance')
    cfg.provisionalVerticalFloorTolerance = 0.08;
end
if ~isfield(cfg, 'maxProvisionalVerticalExcursion')
    cfg.maxProvisionalVerticalExcursion = 0.50;
end
if ~isfield(cfg, 'maxSwingHistorySamples')
    cfg.maxSwingHistorySamples = 400;
end
if ~isfield(cfg, 'initialVerticalSwingBias')
    cfg.initialVerticalSwingBias = 0;
end
if ~isfield(cfg, 'verticalSwingBiasAdaptGain')
    cfg.verticalSwingBiasAdaptGain = 0.08;
end
if ~isfield(cfg, 'maxVerticalSwingBias')
    cfg.maxVerticalSwingBias = 2.0;
end
if ~isfield(cfg, 'verticalBiasMinSwingDuration')
    cfg.verticalBiasMinSwingDuration = 0.25;
end
if ~isfield(cfg, 'verticalBiasMaxSwingDuration')
    cfg.verticalBiasMaxSwingDuration = 1.50;
end
if ~isfield(cfg, 'maxVerticalBiasResidual')
    cfg.maxVerticalBiasResidual = 1.0;
end

end
