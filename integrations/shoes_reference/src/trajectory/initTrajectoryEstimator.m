function estimator = initTrajectoryEstimator(cfg)
% initTrajectoryEstimator  Initialize IMU trajectory estimator with pressure ZUPT.

if nargin < 1
    cfg = struct();
end

cfg = fillTrajectoryDefaults(cfg);

estimator = struct();
estimator.cfg = cfg;
estimator.left = initOneFootTrajectoryState(cfg, 'left');
estimator.right = initOneFootTrajectoryState(cfg, 'right');
estimator.lastUpdateT = NaN;

end

function s = initOneFootTrajectoryState(cfg, side)

s = struct();
s.pos = [0 0 0];
s.displayPos = [0 0 0];
s.vel = [0 0 0];
s.accWorld = [0 0 0];
s.accWorldRaw = [0 0 0];
s.lastAccWorld = [0 0 0];
s.accBias = [0 0 0];
s.calibrationAccBiasInitialized = false;
s.bodyAccBias = [0 0 0];
s.bodyAccBiasInitialized = false;
s.swingVerticalBias = getInitialVerticalSwingBias(cfg, side);
s.lastVerticalSwingBiasResidual = NaN;
s.contact = true;
s.lastContact = true;
s.pendingContact = true;
s.pendingContactStartT = NaN;
s.stanceStartT = NaN;
s.swingStartT = NaN;
s.lastStanceDuration = NaN;
s.lastSwingDuration = NaN;
s.zuptActive = true;
s.totalPressure = 0;
s.activeSensorCount = 0;
s.loadIndex = 0;
s.lastT = [];
s.lastQuatWxyz = [1 0 0 0];
s.referenceYawRad = NaN;
s.headingOffsetRad = 0;
s.lastDt = NaN;
s.dtSkipped = false;
s.standingTotalPressure = NaN;
s.biasAdaptGain = cfg.biasAdaptGain;
s.stepEvent = false;
s.stepCount = 0;
s.initialLandingAnchored = false;
s.lastLandingT = NaN;
s.lastLandingPos = [NaN NaN NaN];
s.rawLandingPos = [NaN NaN NaN];
s.rawStepLength = NaN;
s.preZuptVelocity = [NaN NaN NaN];
s.lastLandingCorrection = [0 0 0];
s.swingHistoryT = zeros(0, 1);
s.swingHistoryPos = zeros(0, 3);
s.swingHistoryVel = zeros(0, 3);
s.lastCorrectedSwingT = zeros(0, 1);
s.lastCorrectedSwingPos = zeros(0, 3);
s.lastCorrectedSwingVel = zeros(0, 3);
s.lastRawSwingT = zeros(0, 1);
s.lastRawSwingPos = zeros(0, 3);
s.lastRawSwingVel = zeros(0, 3);
s.stepLength = NaN;
s.stepCadence = NaN;
s.stepSpeed = NaN;
s.suspiciousStep = false;
s.longSwingWarning = false;
s.missedLandingSuspected = false;

end

function bias = getInitialVerticalSwingBias(cfg, side)

bias = 0;
if ~isfield(cfg, 'initialVerticalSwingBias')
    return;
end

value = cfg.initialVerticalSwingBias;
if isstruct(value) && isfield(value, side)
    value = value.(side);
end
if isnumeric(value) && isscalar(value) && isfinite(value)
    bias = double(value);
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
