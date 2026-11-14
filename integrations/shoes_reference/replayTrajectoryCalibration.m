function report = replayTrajectoryCalibration(testDir, cfg)
% replayTrajectoryCalibration  Replay decoded logs with the trajectory estimator.
%
% The default manual lengths are the July 26 straight-walk calibration:
% nine left-foot movements and nine right-foot movements, in metres.

projectRoot = setupGaitProject();
if nargin < 1 || isempty(testDir)
    testDir = fullfile(projectRoot, 'data', 'calibration_walks');
end
if nargin < 2 || isempty(cfg)
    cfg = makeReplayTrajectoryConfig();
end

truth.left = [0.48 0.81 0.74 0.62 0.86 0.85 0.89 0.97 1.11];
truth.right = [0.80 0.77 0.70 0.76 0.99 0.78 0.93 1.09 0.53];
truthSessions = ["20260726_212216" "20260726_212300" "20260726_212403"];

imuFiles = dir(fullfile(testDir, 'imu_decoded_*.csv'));
if isempty(imuFiles)
    error('No imu_decoded_*.csv files found in %s.', testDir);
end

allSteps = table();
summaryRows = cell(2 * numel(imuFiles), 9);
summaryCount = 0;
for fileIndex = 1:numel(imuFiles)
    stamp = extractSessionStamp(imuFiles(fileIndex).name);
    [steps, estimator] = replayOneSession(testDir, stamp, cfg);
    steps.trial = repmat(string(stamp), height(steps), 1);

    for side = ["left" "right"]
        mask = steps.foot == side;
        sideSteps = sortrows(steps(mask, :), 'step_index');
        hasManualTruth = any(string(stamp) == truthSessions);
        if hasManualTruth
            expected = truth.(char(side));
        else
            expected = [];
        end
        matchedCount = min(height(sideSteps), numel(expected));

        sideSteps.true_step_length_m = NaN(height(sideSteps), 1);
        sideSteps.error_m = NaN(height(sideSteps), 1);
        if matchedCount > 0
            sideSteps.true_step_length_m(1:matchedCount) = expected(1:matchedCount).';
            sideSteps.error_m(1:matchedCount) = ...
                sideSteps.step_length_m(1:matchedCount) - expected(1:matchedCount).';
        end
        steps(mask, :) = sideSteps(:, steps.Properties.VariableNames);

        validErrors = sideSteps.error_m(isfinite(sideSteps.error_m));
        finalPos = estimator.(char(side)).pos;
        summaryCount = summaryCount + 1;
        expectedTotal = sum(expected);
        if isempty(expected)
            expectedTotal = NaN;
        end
        summaryRows(summaryCount, :) = {string(stamp), side, height(sideSteps), ...
            mean(abs(validErrors)), sqrt(mean(validErrors .^ 2)), mean(validErrors), ...
            sum(sideSteps.step_length_m, 'omitnan'), expectedTotal, norm(finalPos(1:2))};
    end

    allSteps = [allSteps; steps]; %#ok<AGROW>
end

summaryRows = summaryRows(1:summaryCount, :);
summary = cell2table(summaryRows, 'VariableNames', { ...
    'trial', 'foot', 'detected_steps', 'mae_m', 'rmse_m', 'bias_m', ...
    'calculated_total_m', 'true_total_m', 'final_displacement_m'});

validErrors = allSteps.error_m(isfinite(allSteps.error_m));
report = struct();
report.testDir = string(testDir);
report.config = cfg;
report.steps = allSteps;
report.summary = summary;
report.overallMAE = mean(abs(validErrors));
report.overallRMSE = sqrt(mean(validErrors .^ 2));
report.overallBias = mean(validErrors);
report.rawZMaxAbs = max(abs([allSteps.raw_z_min; allSteps.raw_z_max]), [], 'omitnan');
report.correctedZMaxAbs = max(abs([allSteps.corrected_z_min; ...
    allSteps.corrected_z_max]), [], 'omitnan');

disp(summary);
fprintf('Overall: MAE %.1f cm, RMSE %.1f cm, bias %+.1f cm (%d matched steps).\n', ...
    100 * report.overallMAE, 100 * report.overallRMSE, ...
    100 * report.overallBias, numel(validErrors));
fprintf('Vertical excursion: raw max |Z| %.1f cm, corrected max |Z| %.1f cm.\n', ...
    100 * report.rawZMaxAbs, 100 * report.correctedZMaxAbs);

end

function [steps, estimator] = replayOneSession(testDir, stamp, cfg)

imu = readtable(fullfile(testDir, sprintf('imu_decoded_%s.csv', stamp)), ...
    'VariableNamingRule', 'preserve');
pressure = readtable(fullfile(testDir, sprintf('pressure_decoded_%s.csv', stamp)), ...
    'VariableNamingRule', 'preserve');

calibrationFile = fullfile(testDir, sprintf('calibration_%s.csv', stamp));
calib = readRecordedCalibration(calibrationFile);
for side = ["left" "right"]
    if ~isfield(calib, char(side)) || isempty(fieldnames(calib.(char(side))))
        calib.(char(side)) = estimateReplayCalibration(imu, pressure, side);
    end
end

if ismember('phase', imu.Properties.VariableNames)
    imu = imu(string(imu.phase) == "recording", :);
end
if ismember('phase', pressure.Properties.VariableNames)
    pressure = pressure(string(pressure.phase) == "recording", :);
end
if ismember('stream_accepted', imu.Properties.VariableNames)
    imu = imu(logical(imu.stream_accepted), :);
end
if ismember('stream_accepted', pressure.Properties.VariableNames)
    pressure = pressure(logical(pressure.stream_accepted), :);
end

nImu = height(imu);
nPressure = height(pressure);
eventT = [double(imu.t); double(pressure.t)];
eventType = [zeros(nImu, 1); ones(nPressure, 1)];
eventRow = [(1:nImu)'; (1:nPressure)'];
[~, order] = sortrows([eventT eventType], [1 2]);

estimator = initTrajectoryEstimator(cfg);
    stepRows = cell(nPressure, 24);
stepRowCount = 0;
pressureNames = compose('p%02d', 1:48);

for orderIndex = 1:numel(order)
    eventIndex = order(orderIndex);
    isPressure = eventType(eventIndex) == 1;
    rowIndex = eventRow(eventIndex);

    if isPressure
        foot = string(pressure.foot{rowIndex});
        t = double(pressure.t(rowIndex));
    else
        foot = string(imu.foot{rowIndex});
        t = double(imu.t(rowIndex));
    end

    side = char(foot);
    sample = struct();
    sample.t = t;
    sample.(side).t = t;
    sample.(side).calib = calib.(side);

    if isPressure
        values = double(pressure{rowIndex, pressureNames});
        values = max(values - calib.(side).pressureZero, 0);
        pressureMsg.data.sum = sum(values);
        pressureMsg.data.values = values(:).';
        pressureMsg.recv_time_sec = t;
        sample.(side).pressure = pressureMsg;
    else
        imuMsg.data.acc_ms2 = double(imu{rowIndex, {'accX_ms2', 'accY_ms2', 'accZ_ms2'}});
        imuMsg.data.acc_g = double(imu{rowIndex, {'accX_g', 'accY_g', 'accZ_g'}});
        imuMsg.data.q_wxyz = double(imu{rowIndex, {'q_w', 'q_x', 'q_y', 'q_z'}});
        imuMsg.recv_time_sec = t;
        sample.(side).imu = imuMsg;
    end

    estimator = updateTrajectoryEstimator(estimator, sample, cfg);
    footState = estimator.(side);
    if footState.stepEvent
        correction = footState.lastLandingCorrection;
        preZuptVelocity = footState.preZuptVelocity;
        landingPos = footState.lastLandingPos;
        [rawZMin, rawZMax] = getReplayVerticalRange(footState.lastRawSwingPos);
        [correctedZMin, correctedZMax] = ...
            getReplayVerticalRange(footState.lastCorrectedSwingPos);
        stepRowCount = stepRowCount + 1;
        stepRows(stepRowCount, 1:18) = { ...
            foot, footState.stepCount, footState.swingStartT, footState.lastLandingT, ...
            footState.lastSwingDuration, footState.stepLength, footState.rawStepLength, ...
            correction(1), correction(2), correction(3), ...
            preZuptVelocity(1), preZuptVelocity(2), preZuptVelocity(3), ...
            landingPos(1), landingPos(2), landingPos(3), NaN, NaN};
        stepRows(stepRowCount, 19:24) = { ...
            rawZMin, rawZMax, correctedZMin, correctedZMax, ...
            footState.swingVerticalBias, footState.lastVerticalSwingBiasResidual};
    end
end

stepRows = stepRows(1:stepRowCount, :);
steps = cell2table(stepRows, 'VariableNames', { ...
    'foot', 'step_index', 'lift_time', 'land_time', 'swing_duration_s', ...
    'step_length_m', 'raw_step_length_m', ...
    'zupt_correction_x', 'zupt_correction_y', 'zupt_correction_z', ...
    'pre_zupt_vel_x', 'pre_zupt_vel_y', 'pre_zupt_vel_z', ...
    'landing_pos_x', 'landing_pos_y', 'landing_pos_z', ...
    'true_step_length_m', 'error_m', ...
    'raw_z_min', 'raw_z_max', 'corrected_z_min', 'corrected_z_max', ...
    'vertical_swing_bias', 'vertical_bias_residual'});
steps.foot = string(steps.foot);

end

function [zMin, zMax] = getReplayVerticalRange(positions)

zMin = NaN;
zMax = NaN;
if isempty(positions) || size(positions, 2) < 3
    return;
end

z = double(positions(:, 3));
z = z(isfinite(z));
if ~isempty(z)
    zMin = min(z);
    zMax = max(z);
end

end

function calib = estimateReplayCalibration(imu, pressure, foot)

pressureMask = string(pressure.foot) == foot & isfinite(pressure.total) & pressure.total > 0;
standingTotals = double(pressure.total(pressureMask));
sampleCount = min(40, numel(standingTotals));
if sampleCount == 0
    error('No standing pressure samples found for %s foot.', foot);
end

imuMask = string(imu.foot) == foot;
q = double(imu{imuMask, {'q_w', 'q_x', 'q_y', 'q_z'}});
q = q(1:min(100, size(q, 1)), :);
if isempty(q)
    error('No IMU quaternion samples found for %s foot.', foot);
end

reference = q(1, :);
for rowIndex = 1:size(q, 1)
    if dot(q(rowIndex, :), reference) < 0
        q(rowIndex, :) = -q(rowIndex, :);
    end
end

q0 = mean(q, 1);
q0 = q0 ./ max(norm(q0), 1e-12);
calib = struct();
calib.standingTotalPressure = mean(standingTotals(1:sampleCount));
calib.q0_wxyz = q0;
calib.bodyAccBias = [0 0 0];
calib.accNavBias = [0 0 0];
calib.pressureZero = zeros(1, 48);

end

function calibration = readRecordedCalibration(fileName)

calibration.left = struct();
calibration.right = struct();
if exist(fileName, 'file') ~= 2
    return;
end

values = readtable(fileName, 'VariableNamingRule', 'preserve');
if isempty(values) || ~all(ismember({'event', 'foot'}, ...
        values.Properties.VariableNames))
    return;
end

pressureZeroNames = cellstr(compose('pressure_zero_%02d', 1:48));
for side = ["left" "right"]
    mask = string(values.event) == "worn" & string(values.foot) == side;
    rowIndex = find(mask, 1, 'last');
    if isempty(rowIndex)
        continue;
    end

    row = values(rowIndex, :);
    result = struct();
    result.standingTotalPressure = double(row.standing_total);
    result.standingCOP = double(row{1, {'standing_cop_x', 'standing_cop_y'}});
    result.q0_wxyz = double(row{1, {'q0_w', 'q0_x', 'q0_y', 'q0_z'}});
    result.bodyAccBias = double(row{1, { ...
        'body_acc_bias_x', 'body_acc_bias_y', 'body_acc_bias_z'}});
    result.accNavBias = double(row{1, { ...
        'nav_acc_bias_x', 'nav_acc_bias_y', 'nav_acc_bias_z'}});
    if all(ismember(pressureZeroNames, values.Properties.VariableNames))
        result.pressureZero = double(row{1, pressureZeroNames});
    else
        result.pressureZero = zeros(1, 48);
    end
    calibration.(char(side)) = result;
end

end

function stamp = extractSessionStamp(fileName)

tokens = regexp(fileName, ...
    '^imu_decoded_(\d{8}_\d{6}(?:_\d{3})?)\.csv$', 'tokens', 'once');
if isempty(tokens)
    error('Cannot extract session stamp from %s.', fileName);
end
stamp = tokens{1};

end

function cfg = makeReplayTrajectoryConfig()

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
cfg.maxSpeed = 4.0;
cfg.maxReasonableStepLength = 1.5;
cfg.biasAdaptGain = 0.01;
cfg.accDeadband = 0.15;
cfg.quatDirection = "bodyToWorld";
cfg.gravityRemovalMode = "bodyThenWorld";
cfg.accUnit = "g";
cfg.useVertical = true;
cfg.lockVerticalOnContact = true;
cfg.groundZ = 0;
cfg.activeSensorContactEnable = true;
cfg.activePressureThreshold = 200;
cfg.activeSensorsOn = 4;
cfg.activeSensorsOff = 3;
cfg.landingVelocityCorrectionGain = 1.5;
cfg.maxLandingCorrection = 2.0;
cfg.verticalFloorTolerance = 0.02;
cfg.maxCorrectedVerticalExcursion = 0.35;
cfg.provisionalVerticalFloorTolerance = 0.08;
cfg.maxProvisionalVerticalExcursion = 0.50;
cfg.maxSwingHistorySamples = 400;
cfg.initialVerticalSwingBias.left = 0;
cfg.initialVerticalSwingBias.right = 0;
cfg.verticalSwingBiasAdaptGain = 0.08;
cfg.maxVerticalSwingBias = 2.0;
cfg.verticalBiasMinSwingDuration = 0.25;
cfg.verticalBiasMaxSwingDuration = 1.50;
cfg.maxVerticalBiasResidual = 1.0;
cfg.alignHeadingToCalibration = true;
cfg.headingOffsetDeg.left = -79;
cfg.headingOffsetDeg.right = -99;

end
