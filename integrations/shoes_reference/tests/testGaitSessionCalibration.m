function tests = testGaitSessionCalibration
% Tests for the guided empty-shoe and worn preparation workflow.

tests = functiontests(localfunctions);

end

function testCompleteWorkflow(testCase)

cfg = makeCalibrationTestConfig();
session = initGaitSessionState();
[session, event] = startGaitSessionPhase(session, "start_unloaded", NaN);
verifyTrue(testCase, event.accepted);
verifyTrue(testCase, isfield(event, 'startTimeAlignment'));
verifyFalse(testCase, event.startTimeAlignment);
verifyTrue(testCase, isfield(event, 'resetAlignmentRuntime'));
verifyFalse(testCase, event.resetAlignmentRuntime);
verifyEqual(testCase, session.phase, "unloaded_calibration");

bias.left = [0.10 -0.20 0.30];
bias.right = [-0.15 0.05 -0.25];
for side = ["left" "right"]
    [session, completedEvents] = feedUnloadedSamples( ...
        session, side, bias.(char(side)), cfg);
    verifyEqual(testCase, completedEvents, 1);
    verifyEqual(testCase, ...
        session.calibration.(char(side)).bodyAccBias, ...
        bias.(char(side)), 'AbsTol', 1e-12);
end
verifyTrue(testCase, session.unloadedComplete);
verifyEqual(testCase, session.phase, "unloaded_complete");

[session, event] = startGaitSessionPhase(session, "start_worn", NaN);
verifyTrue(testCase, event.accepted);
for side = ["left" "right"]
    [session, completedEvents] = feedWornSamples(session, side, bias.(char(side)), cfg);
    verifyEqual(testCase, completedEvents, 1);
end
verifyTrue(testCase, session.wornComplete);
verifyEqual(testCase, session.phase, "ready_to_record");
verifyEqual(testCase, ...
    session.calibration.left.standingTotalPressure, 1600, ...
    'AbsTol', 1e-12);

[session, event] = startGaitSessionPhase(session, "start_recording", 10);
verifyTrue(testCase, event.accepted);
verifyTrue(testCase, event.resetRuntime);
verifyEqual(testCase, session.phase, "recording");
verifyEqual(testCase, session.recordingStartT, 10);

[session, event] = startGaitSessionPhase(session, "stop_recording", 20);
verifyTrue(testCase, event.accepted);
verifyTrue(testCase, event.stopRequested);
verifyEqual(testCase, session.phase, "finished");
verifyEqual(testCase, session.recordingStopT, 20);

end

function testMovementRestartsEmptyShoeWindow(testCase)

cfg = makeCalibrationTestConfig();
session = initGaitSessionState();
[session, ~] = startGaitSessionPhase(session, "start_unloaded", NaN);

for t = 0:0.01:0.05
    msg = makeImuMessage("left", t, [0 0 cfg.trajectory.gravity], [1 0 0 0]);
    session = updateGaitSessionCalibration(session, msg, cfg);
end
verifyGreaterThan(testCase, numel(session.unloaded.left.imuT), 1);

qYaw90 = [sqrt(0.5) 0 0 sqrt(0.5)];
msg = makeImuMessage("left", 0.06, ...
    [0 0 cfg.trajectory.gravity], qYaw90);
session = updateGaitSessionCalibration(session, msg, cfg);

verifyEmpty(testCase, session.unloaded.left.imuT);
verifyNotEmpty(testCase, char(session.unloaded.left.lastIssue));

end

function testCalibrationLogContainsReplayParameters(testCase)

fileName = [tempname '.csv'];
cleanupObj = onCleanup(@() deleteIfPresent(fileName)); %#ok<NASGU>
initializeGaitCalibrationLog(fileName);

result = struct();
result.imuSamples = 500;
result.pressureSamples = 100;
result.durationSec = 5;
result.bodyAccBias = [0.1 -0.2 0.3];
result.bodyAccNoise = [0.01 0.02 0.03];
result.accNavBias = [0.04 -0.05 0.06];
result.standingTotalPressure = 4000;
result.standingCOP = [0.4 0.5];
result.q0_wxyz = [1 0 0 0];
result.angularRateP95Deg = 0.8;
result.loadVariation = 0.03;
result.pressureZero = 1:48;
result.pressureNoise = (1:48) / 10;
appendGaitCalibrationLog(fileName, "worn", "left", result, 123.456, "passed");

values = readtable(fileName, 'VariableNamingRule', 'preserve');
verifyEqual(testCase, height(values), 1);
verifyEqual(testCase, string(values.event), "worn");
verifyEqual(testCase, string(values.foot), "left");
verifyEqual(testCase, values.body_acc_bias_z, 0.3, 'AbsTol', 1e-12);
verifyEqual(testCase, values.pressure_zero_48, 48, 'AbsTol', 1e-12);
verifyEqual(testCase, values.pressure_noise_48, 4.8, 'AbsTol', 1e-12);

end

function [session, completedEvents] = feedUnloadedSamples(session, side, bias, cfg)

completedEvents = 0;
for t = 0:0.01:0.13
    if mod(round(t * 100), 4) == 0
        pressureMsg = makePressureMessage(side, t, zeros(1, 48));
        [session, event] = updateGaitSessionCalibration(session, pressureMsg, cfg);
        completedEvents = completedEvents + double(event.completed);
    end
    accBody = [0 0 cfg.trajectory.gravity] + bias;
    imuMsg = makeImuMessage(side, t, accBody, [1 0 0 0]);
    [session, event] = updateGaitSessionCalibration(session, imuMsg, cfg);
    completedEvents = completedEvents + double(event.completed);
end

end

function [session, completedEvents] = feedWornSamples(session, side, bias, cfg)

completedEvents = 0;
P = zeros(1, 48);
P(1:4) = 400;
for t = 1:0.01:1.13
    if mod(round((t - 1) * 100), 4) == 0
        pressureMsg = makePressureMessage(side, t, P);
        [session, event] = updateGaitSessionCalibration(session, pressureMsg, cfg);
        completedEvents = completedEvents + double(event.completed);
    end
    accBody = [0 0 cfg.trajectory.gravity] + bias;
    imuMsg = makeImuMessage(side, t, accBody, [1 0 0 0]);
    [session, event] = updateGaitSessionCalibration(session, imuMsg, cfg);
    completedEvents = completedEvents + double(event.completed);
end

end

function msg = makeImuMessage(side, t, accBody, q)

msg = struct();
msg.foot = char(side);
msg.sensor_type = 'imu';
msg.recv_time_sec = t;
msg.data.acc_ms2 = accBody;
msg.data.acc_g = accBody / 9.80665;
msg.data.q_wxyz = q;

end

function msg = makePressureMessage(side, t, P)

msg = struct();
msg.foot = char(side);
msg.sensor_type = 'pressure';
msg.recv_time_sec = t;
msg.data.values = P;
msg.data.sum = sum(P);

end

function cfg = makeCalibrationTestConfig()

cfg.trajectory.gravity = 9.80665;
cfg.gait.heelRows = 1:3;
cfg.gait.midRows = 4:7;
cfg.gait.foreRows = 8:10;
cfg.gait.toeRows = 11:12;
cfg.gait.medialCols = 3:4;
cfg.gait.lateralCols = 1:2;
cfg.calib.unloadedDurationSec = 0.10;
cfg.calib.unloadedPressureDurationSec = 0.08;
cfg.calib.unloadedMinImuSamples = 10;
cfg.calib.unloadedMinPressureSamples = 3;
cfg.calib.unloadedPressureActiveThreshold = 200;
cfg.calib.unloadedMaxActiveSensors = 3;
cfg.calib.unloadedMaxAccNormError = 1.0;
cfg.calib.unloadedMaxAngularRateDeg = 8.0;
cfg.calib.unloadedMaxAccNoise = 0.20;
cfg.calib.wornDurationSec = 0.10;
cfg.calib.wornMinImuSamples = 10;
cfg.calib.wornMinPressureSamples = 3;
cfg.calib.wornPressureActiveThreshold = 200;
cfg.calib.wornMinActiveSensors = 3;
cfg.calib.wornMinTotalPressure = 300;
cfg.calib.wornMaxPressureAgeSec = 0.08;
cfg.calib.wornMaxAccNormError = 1.0;
cfg.calib.wornMaxAngularRateDeg = 15.0;
cfg.calib.wornMaxLoadVariation = 0.25;
cfg.calib.wornMaxCopNoise = 0.12;

end

function deleteIfPresent(fileName)

if exist(fileName, 'file') == 2
    delete(fileName);
end

end
