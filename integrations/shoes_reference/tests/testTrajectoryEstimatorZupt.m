function tests = testTrajectoryEstimatorZupt
% Tests for pressure contact and landing ZUPT corrections.

tests = functiontests(localfunctions);

end

function testActiveSensorLandingAndToeOff(testCase)

cfg = makeTestConfig();
estimator = initTrajectoryEstimator(cfg);

sample = makePressureSample(0, 4000, 12, cfg.activePressureThreshold);
sample.left.calib.standingTotalPressure = 4000;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);
verifyTrue(testCase, estimator.left.contact);

sample = makePressureSample(1, 500, 2, cfg.activePressureThreshold);
sample.left.calib.standingTotalPressure = 4000;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);
verifyFalse(testCase, estimator.left.contact);

sample = makePressureSample(1.8, 1000, 4, cfg.activePressureThreshold);
sample.left.calib.standingTotalPressure = 4000;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);
verifyTrue(testCase, estimator.left.contact);
verifyTrue(testCase, estimator.left.stepEvent);
verifyEqual(testCase, estimator.left.stepCount, 1);

end

function testLandingVelocityCorrection(testCase)

cfg = makeTestConfig();
estimator = initTrajectoryEstimator(cfg);
estimator.left.contact = false;
estimator.left.lastContact = false;
estimator.left.pendingContact = false;
estimator.left.pendingContactStartT = 0;
estimator.left.swingStartT = 0;
estimator.left.initialLandingAnchored = true;
estimator.left.lastLandingT = 0;
estimator.left.lastLandingPos = [0 0 0];
estimator.left.pos = [1 0 -0.4];
estimator.left.displayPos = estimator.left.pos;
estimator.left.vel = [-0.4 0 -0.5];
estimator.left.swingHistoryT = [0; 0.5];
estimator.left.swingHistoryPos = [0 0 0; 0.6 0 -0.15];
estimator.left.swingHistoryVel = [0 0 0; -0.1 0 -0.3];

sample = makePressureSample(1, 1600, 4, cfg.activePressureThreshold);
sample.left.calib.standingTotalPressure = 4000;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);

verifyEqual(testCase, estimator.left.rawStepLength, 1, 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.lastLandingCorrection(1), 0.3, 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.lastLandingCorrection(3), 0.4, 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.stepLength, 1.3, 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.vel, [0 0 0], 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.lastCorrectedSwingPos(end, :), ...
    [1.3 0 0], 'AbsTol', 1e-12);
verifyLessThanOrEqual(testCase, ...
    max(abs(estimator.left.lastCorrectedSwingPos(:, 3))), ...
    cfg.maxCorrectedVerticalExcursion);
verifyEqual(testCase, estimator.left.lastVerticalSwingBiasResidual, ...
    -0.65, 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.swingVerticalBias, ...
    -0.7775, 'AbsTol', 1e-12);

end

function testInitialYawAlignment(testCase)

cfg = makeTestConfig();
cfg.headingOffsetDeg.left = 0;
estimator = initTrajectoryEstimator(cfg);
qYaw90 = [sqrt(0.5) 0 0 sqrt(0.5)];

sample = makePressureSample(0, 4000, 12, cfg.activePressureThreshold);
sample.left.calib.standingTotalPressure = 4000;
sample.left.calib.q0_wxyz = qYaw90;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);

sample = struct();
sample.t = 0.01;
sample.left.t = 0.01;
sample.left.imu.data.acc_ms2 = [0 0 cfg.gravity];
sample.left.imu.data.q_wxyz = qYaw90;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);

verifyEqual(testCase, estimator.left.lastQuatWxyz, [1 0 0 0], 'AbsTol', 1e-12);

end

function testTiltedGravityIsRemovedUsingQuaternion(testCase)

cfg = makeTestConfig();
cfg.alignHeadingToCalibration = false;
estimator = initTrajectoryEstimator(cfg);
pitch = deg2rad(30);
qBodyToWorld = [cos(pitch / 2) 0 sin(pitch / 2) 0];
gravityBody = quatRotateVectorWxyz(quatConjWxyz(qBodyToWorld), ...
    [0 0 cfg.gravity]);

sample = struct();
sample.t = 0;
sample.left.t = 0;
sample.left.imu.data.acc_ms2 = gravityBody;
sample.left.imu.data.q_wxyz = qBodyToWorld;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);

verifyEqual(testCase, estimator.left.accWorldRaw, [0 0 0], 'AbsTol', 1e-10);

end

function testBodyFrameAccelerometerBiasIsRemovedBeforeRotation(testCase)

cfg = makeTestConfig();
cfg.alignHeadingToCalibration = false;
estimator = initTrajectoryEstimator(cfg);
bodyBias = [0.12 -0.08 0.20];

sample = struct();
sample.t = 0;
sample.left.t = 0;
sample.left.calib.bodyAccBias = bodyBias;
sample.left.calib.accNavBias = [0.01 -0.02 0.03];
sample.left.imu.data.acc_ms2 = [0 0 cfg.gravity] + bodyBias;
sample.left.imu.data.q_wxyz = [1 0 0 0];
estimator = updateTrajectoryEstimator(estimator, sample, cfg);

verifyTrue(testCase, estimator.left.bodyAccBiasInitialized);
verifyTrue(testCase, estimator.left.calibrationAccBiasInitialized);
verifyEqual(testCase, estimator.left.bodyAccBias, bodyBias, 'AbsTol', 1e-12);
verifyEqual(testCase, estimator.left.accWorldRaw, [0 0 0], 'AbsTol', 1e-12);

end

function testVerticalBiasIgnoresImplausiblyLongSwing(testCase)

cfg = makeTestConfig();
estimator = initTrajectoryEstimator(cfg);
estimator.left.contact = false;
estimator.left.lastContact = false;
estimator.left.pendingContact = false;
estimator.left.pendingContactStartT = 0;
estimator.left.swingStartT = 0;
estimator.left.initialLandingAnchored = true;
estimator.left.lastLandingT = 0;
estimator.left.lastLandingPos = [0 0 0];
estimator.left.pos = [1 0 -0.4];
estimator.left.displayPos = estimator.left.pos;
estimator.left.vel = [0 0 -0.5];
estimator.left.lastVerticalSwingBiasResidual = 0.9;
initialBias = estimator.left.swingVerticalBias;

sample = makePressureSample(2, 1600, 4, cfg.activePressureThreshold);
sample.left.calib.standingTotalPressure = 4000;
estimator = updateTrajectoryEstimator(estimator, sample, cfg);

verifyEqual(testCase, estimator.left.swingVerticalBias, initialBias, ...
    'AbsTol', 1e-12);
verifyTrue(testCase, isnan(estimator.left.lastVerticalSwingBiasResidual));

end

function testTrajectoryFigureShowsBothFootLandings(testCase)

oldVisibility = get(groot, 'DefaultFigureVisible');
set(groot, 'DefaultFigureVisible', 'off');
visibilityCleanup = onCleanup( ...
    @() set(groot, 'DefaultFigureVisible', oldVisibility)); %#ok<NASGU>

cfg = makeTestConfig();
cfg.axisLimit = [-2 2 -2 2 -0.5 1.5];
cfg.maxPoints = 100;
estimator = initTrajectoryEstimator(cfg);
estimator.lastUpdateT = 0;
h = updateTrajectoryFigure([], estimator, cfg);
figureCleanup = onCleanup(@() closeFigureIfValid(h.fig)); %#ok<NASGU>

estimator.lastUpdateT = 1;
estimator.left.stepCount = 1;
estimator.left.lastLandingPos = [1 0 0];
estimator.left.displayPos = [1 0 0];
estimator.left.lastCorrectedSwingT = [0; 1];
estimator.left.lastCorrectedSwingPos = [0 0 0; 1 0 0];
estimator.right.stepCount = 1;
estimator.right.lastLandingPos = [0.8 0.2 0];
estimator.right.displayPos = [0.8 0.2 0];
estimator.right.lastCorrectedSwingT = [0; 1];
estimator.right.lastCorrectedSwingPos = [0 0 0; 0.8 0.2 0];
h = updateTrajectoryFigure(h, estimator, cfg);

verifyEqual(testCase, h.leftLandingPos, [1 0 0], 'AbsTol', 1e-12);
verifyEqual(testCase, h.rightLandingPos, [0.8 0.2 0], 'AbsTol', 1e-12);
verifyEqual(testCase, string(h.leftLandingText(1).String), "1");
verifyEqual(testCase, string(h.rightLandingText(1).String), "1");
verifyEqual(testCase, h.leftLandingText(1).Parent, h.leftAx);
verifyEqual(testCase, h.rightLandingText(1).Parent, h.rightAx);
verifyEqual(testCase, numel(h.leftTrace.XData), 2);
verifyEqual(testCase, numel(h.rightTrace.XData), 2);
verifyEqual(testCase, h.leftAx.XLim, h.rightAx.XLim, 'AbsTol', 1e-12);
verifyEqual(testCase, h.leftAx.YLim, h.rightAx.YLim, 'AbsTol', 1e-12);

estimator.lastUpdateT = 2;
estimator.left.stepCount = 2;
estimator.left.lastLandingPos = [2 0 0];
estimator.left.displayPos = [2 0 0];
estimator.left.lastCorrectedSwingT = [1; 2];
estimator.left.lastCorrectedSwingPos = [1 0 0; 2 0 0];
h = updateTrajectoryFigure(h, estimator, cfg);

verifyEqual(testCase, size(h.leftLandingPos, 1), 2);
verifyEqual(testCase, size(h.rightLandingPos, 1), 1);
verifyEqual(testCase, string(h.leftLandingText(2).String), "2");

end

function testTrajectoryFigureRepeatedUpdatesKeepLineDataShapesValid(testCase)

oldVisibility = get(groot, 'DefaultFigureVisible');
set(groot, 'DefaultFigureVisible', 'off');
visibilityCleanup = onCleanup( ...
    @() set(groot, 'DefaultFigureVisible', oldVisibility)); %#ok<NASGU>

cfg = makeTestConfig();
cfg.axisLimit = [-2 2 -2 2 -0.5 1.5];
cfg.maxPoints = 80;
verifyWarningFree(testCase, @() runTrajectoryGraphicsStress(cfg));

end

function runTrajectoryGraphicsStress(cfg)

h = initTrajectoryFigure(cfg);
figureCleanup = onCleanup(@() closeFigureIfValid(h.fig)); %#ok<NASGU>
estimator = initTrajectoryEstimator(cfg);
leftStepCount = 0;
rightStepCount = 0;

for sampleIndex = 1:240
    t = 0.1 * sampleIndex;
    estimator.lastUpdateT = t;
    estimator.left.displayPos = [0.025 * sampleIndex, 0.12, ...
        0.08 * max(0, sin(0.25 * pi * sampleIndex))];
    estimator.right.displayPos = [0.025 * sampleIndex - 0.3, -0.12, ...
        0.08 * max(0, sin(0.25 * pi * sampleIndex + pi))];

    if mod(sampleIndex, 20) == 0
        leftStepCount = leftStepCount + 1;
        estimator.left.stepCount = leftStepCount;
        estimator.left.lastLandingPos = ...
            [estimator.left.displayPos(1:2) 0];
        [estimator.left.lastCorrectedSwingT, ...
            estimator.left.lastCorrectedSwingPos] = ...
            makeCorrectedSwing(t, estimator.left.lastLandingPos);
    end
    if mod(sampleIndex, 20) == 10
        rightStepCount = rightStepCount + 1;
        estimator.right.stepCount = rightStepCount;
        estimator.right.lastLandingPos = ...
            [estimator.right.displayPos(1:2) 0];
        [estimator.right.lastCorrectedSwingT, ...
            estimator.right.lastCorrectedSwingPos] = ...
            makeCorrectedSwing(t, estimator.right.lastLandingPos);
    end

    h = updateTrajectoryFigure(h, estimator, cfg);
    assertTrajectoryLineShapes(h);
    assertPositionLineShapes(h, true);
    drawnow;
end

h = resetTrajectoryFigureData(h, cfg);
assertTrajectoryLineShapes(h);
assertPositionLineShapes(h, false);
drawnow;

estimator.lastUpdateT = estimator.lastUpdateT + 0.1;
h = updateTrajectoryFigure(h, estimator, cfg);
assertTrajectoryLineShapes(h);
assertPositionLineShapes(h, true);
drawnow;

end

function [swingT, swingPos] = makeCorrectedSwing(landingT, landingPos)

swingT = linspace(landingT - 0.8, landingT, 81).';
alpha = linspace(0, 1, numel(swingT)).';
swingPos = [ ...
    landingPos(1) - 0.7 + 0.7 * alpha, ...
    landingPos(2) + 0.03 * sin(pi * alpha), ...
    0.10 * sin(pi * alpha)];

end

function assertTrajectoryLineShapes(h)

lineHandles = [ ...
    h.leftTrace h.rightTrace ...
    h.leftLandingMarkers h.rightLandingMarkers ...
    h.leftPoint h.rightPoint h.leftZupt h.rightZupt];
for lineIndex = 1:numel(lineHandles)
    x = get(lineHandles(lineIndex), 'XData');
    y = get(lineHandles(lineIndex), 'YData');
    z = get(lineHandles(lineIndex), 'ZData');
    assert(isequal(size(x), size(y), size(z)), ...
        'A trajectory Line contains incompatible X/Y/Z data shapes.');
end

end

function assertPositionLineShapes(h, requireFiniteData)

lineHandles = [ ...
    h.leftPosXLine h.rightPosXLine ...
    h.leftPosYLine h.rightPosYLine ...
    h.leftPosZLine h.rightPosZLine];
for lineIndex = 1:numel(lineHandles)
    x = get(lineHandles(lineIndex), 'XData');
    y = get(lineHandles(lineIndex), 'YData');
    z = get(lineHandles(lineIndex), 'ZData');
    assert(isequal(size(x), size(y)), ...
        'A position Line contains incompatible X/Y data shapes.');
    assert(isempty(z), 'A 2-D position Line must have empty ZData.');
    if requireFiniteData
        assert(any(isfinite(x)) && any(isfinite(y)), ...
            'A position Line has no finite curve data.');
    end
end

end

function sample = makePressureSample(t, total, activeCount, threshold)

values = zeros(1, 48);
if activeCount > 0
    values(1:activeCount) = max(threshold + 1, total / activeCount);
end

sample = struct();
sample.t = t;
sample.left.t = t;
sample.left.pressure.data.sum = total;
sample.left.pressure.data.values = values;

end

function cfg = makeTestConfig()

cfg = struct();
cfg.gravity = 9.80665;
cfg.contactOn = 0.30;
cfg.contactOff = 0.10;
cfg.pressureOnThreshold = 0.30;
cfg.pressureOffThreshold = 0.10;
cfg.pressureOn = 300;
cfg.pressureOff = 150;
cfg.minStanceDurationMs = 30;
cfg.minSwingDurationMs = 30;
cfg.debounceMs = 0;
cfg.maxSwingDurationMs = 1500;
cfg.maxDt = 0.15;
cfg.minDt = 1e-4;
cfg.maxSpeed = 4;
cfg.maxReasonableStepLength = 1.5;
cfg.biasAdaptGain = 0.01;
cfg.accDeadband = 0.15;
cfg.quatDirection = "bodyToWorld";
cfg.gravityRemovalMode = "bodyThenWorld";
cfg.accUnit = "mps2";
cfg.useVertical = true;
cfg.lockVerticalOnContact = true;
cfg.groundZ = 0;
cfg.activeSensorContactEnable = true;
cfg.activePressureThreshold = 200;
cfg.activeSensorsOn = 4;
cfg.activeSensorsOff = 3;
cfg.landingVelocityCorrectionGain = 1.5;
cfg.maxLandingCorrection = 2;
cfg.verticalFloorTolerance = 0.02;
cfg.maxCorrectedVerticalExcursion = 0.35;
cfg.provisionalVerticalFloorTolerance = 0.08;
cfg.maxProvisionalVerticalExcursion = 0.50;
cfg.maxSwingHistorySamples = 400;
cfg.initialVerticalSwingBias.left = -0.55;
cfg.initialVerticalSwingBias.right = -0.55;
cfg.verticalSwingBiasAdaptGain = 0.35;
cfg.maxVerticalSwingBias = 2.0;
cfg.verticalBiasMinSwingDuration = 0.25;
cfg.verticalBiasMaxSwingDuration = 1.50;
cfg.maxVerticalBiasResidual = 1.0;
cfg.alignHeadingToCalibration = true;
cfg.headingOffsetDeg.left = -79;
cfg.headingOffsetDeg.right = -99;

end

function closeFigureIfValid(fig)

if ~isempty(fig) && isvalid(fig)
    close(fig);
end

end
