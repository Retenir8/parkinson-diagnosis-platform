function tests = testGaitLogSession
% Tests for timestamped per-run log directories.

tests = functiontests(localfunctions);

end

function testAllLogFilesShareTimestampedSessionDirectory(testCase)

projectDir = tempname;
mkdir(projectDir);
cleanupObj = onCleanup(@() removeTestDirectory(projectDir)); %#ok<NASGU>

cfg.log.fileName = 'gait_state.csv';
cfg.log.manifestFileName = 'session_manifest.txt';
cfg.log.manualTemplateFileName = 'manual_steps_template.csv';
cfg.log.calibrationFileName = 'calibration.csv';
cfg.log.timeAlignmentFileName = 'time_alignment.csv';
cfg.rawLog.fileName = 'raw_mqtt_low_latency.csv';
cfg.decodedLog.imuFileName = 'imu_decoded.csv';
cfg.decodedLog.pressureFileName = 'pressure_decoded.csv';
cfg.trajectory.stepMetricsLogFileName = 'step_metrics.csv';
cfg.trajectory.stateLogFileName = 'trajectory_state.csv';
startDt = datetime(2026, 7, 28, 9, 8, 7) + milliseconds(123);

cfg = prepareGaitLogSession(cfg, projectDir, startDt);
expectedDir = fullfile(projectDir, 'log', '20260728_090807_123');

verifyEqual(testCase, cfg.log.sessionDir, expectedDir);
verifyEqual(testCase, cfg.log.fileName, ...
    fullfile(expectedDir, 'gait_state_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.log.manifestFileName, ...
    fullfile(expectedDir, 'session_manifest_20260728_090807_123.txt'));
verifyEqual(testCase, cfg.log.calibrationFileName, ...
    fullfile(expectedDir, 'calibration_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.log.timeAlignmentFileName, ...
    fullfile(expectedDir, 'time_alignment_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.rawLog.fileName, ...
    fullfile(expectedDir, 'raw_mqtt_low_latency_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.decodedLog.imuFileName, ...
    fullfile(expectedDir, 'imu_decoded_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.decodedLog.pressureFileName, ...
    fullfile(expectedDir, 'pressure_decoded_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.trajectory.stepMetricsLogFileName, ...
    fullfile(expectedDir, 'step_metrics_20260728_090807_123.csv'));
verifyEqual(testCase, cfg.trajectory.stateLogFileName, ...
    fullfile(expectedDir, 'trajectory_state_20260728_090807_123.csv'));
verifyEqual(testCase, exist(expectedDir, 'dir'), 7);

end

function removeTestDirectory(projectDir)

if startsWith(projectDir, tempdir) && exist(projectDir, 'dir') == 7
    rmdir(projectDir, 's');
end

end
