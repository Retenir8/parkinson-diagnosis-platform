function runMqttGaitLowLatency()
% Low-latency MQTT gait analysis and CSV storage.
%
% This is the maintained real-time entry point for calibration, recording,
% logging, gait metrics, and trajectory plots.

setupGaitProject();
clc;

cfg = makeLowLatencyConfig();
setappdata(0, cfg.control.appdataKey, '');
monitor = initLatencyMonitor(cfg);
[cfg, gatewaySelectionAccepted] = waitForGatewayConfiguration(monitor, cfg);
if ~gatewaySelectionAccepted
    if isappdata(0, cfg.control.appdataKey)
        rmappdata(0, cfg.control.appdataKey);
    end
    disp('Low-latency monitor start cancelled.');
    return;
end

cfg = prepareGaitLogSession(cfg);
writeSessionManifest(cfg);
initializeGaitCalibrationLog(cfg.log.calibrationFileName);
initializeTimeAlignmentLog(cfg.log.timeAlignmentFileName);

fprintf('Low-latency gait monitor starting...\n');
fprintf('Session log directory: %s\n', cfg.log.sessionDir);
fprintf('Gait state CSV: %s\n', cfg.log.fileName);
fprintf('IMU decoded CSV: %s\n', cfg.decodedLog.imuFileName);
fprintf('Pressure decoded CSV: %s\n', cfg.decodedLog.pressureFileName);
fprintf('Manual annotation template: %s\n', cfg.log.manualTemplateFileName);
fprintf('Calibration CSV: %s\n', cfg.log.calibrationFileName);
fprintf('Time alignment CSV: %s\n', cfg.log.timeAlignmentFileName);
if isfield(cfg, 'rawLog') && isfield(cfg.rawLog, 'enable') && cfg.rawLog.enable
    fprintf('Raw CSV: %s\n', cfg.rawLog.fileName);
end
if isfield(cfg, 'trajectory') && isfield(cfg.trajectory, 'stepMetricsLogEnable') && cfg.trajectory.stepMetricsLogEnable
    fprintf('Step metrics CSV: %s\n', cfg.trajectory.stepMetricsLogFileName);
end
if isfield(cfg, 'trajectory') && isfield(cfg.trajectory, 'stateLogEnable') && cfg.trajectory.stateLogEnable
    fprintf('Trajectory state CSV: %s\n', cfg.trajectory.stateLogFileName);
end
fprintf('Use the control window to run empty-shoe calibration before recording.\n');

runtimeTic = tic;
setappdata(0, cfg.queue.appdataKey, initMessageRingBuffer(cfg.queue.capacity));

logger = openLowLatencyCsvLogger(cfg);
decodedLoggers = openDecodedSensorLoggers(cfg);
rawLogger = openOptionalRawLogger(cfg);
stepMetricsLogger = openOptionalStepMetricsLogger(cfg);
trajectoryLogger = openOptionalTrajectoryStateLogger(cfg);
cleanupObj = onCleanup(@() cleanupLowLatency(logger, decodedLoggers, rawLogger, stepMetricsLogger, trajectoryLogger, cfg)); %#ok<NASGU>
monitor = showAnalysisFigureInitialization(monitor);
plotState = initOptionalPlotState();
plotState = preinitializeAnalysisFigures(plotState, cfg);
trajectoryEstimator = initTrajectoryEstimator(cfg.trajectory);
session = initGaitSessionState();
timeAlignment = initGatewayTimeAlignment(cfg.timeAlignment);
appendTimeAlignmentLog(cfg.log.timeAlignmentFileName, ...
    "alignment_initialized", timeAlignment, timeAlignment.statusMessage);

client = mqttclient(cfg.mqtt.host, ...
    "Port", cfg.mqtt.port, ...
    "Username", cfg.mqtt.username, ...
    "Password", cfg.mqtt.password, ...
    "ClientID", cfg.mqtt.clientID);

subscribe(client, cfg.mqtt.topics.leftImu, ...
    "Callback", @(topic, msg) lowLatencyMqttCallback(topic, msg, cfg.queue.appdataKey, runtimeTic));
subscribe(client, cfg.mqtt.topics.rightImu, ...
    "Callback", @(topic, msg) lowLatencyMqttCallback(topic, msg, cfg.queue.appdataKey, runtimeTic));
subscribe(client, cfg.mqtt.topics.leftPressure, ...
    "Callback", @(topic, msg) lowLatencyMqttCallback(topic, msg, cfg.queue.appdataKey, runtimeTic));
subscribe(client, cfg.mqtt.topics.rightPressure, ...
    "Callback", @(topic, msg) lowLatencyMqttCallback(topic, msg, cfg.queue.appdataKey, runtimeTic));

monitor = showGatewayConnected(monitor, cfg, timeAlignment);
state = initLowLatencyState();
lastStatTic = tic;

disp('Connected. Processing in low-latency mode...');

while true
    loopStart = tic;

    [session, timeAlignment, commandEvent] = consumeSessionCommand( ...
        session, state, timeAlignment, cfg);
    if commandEvent.accepted
        appendGaitCalibrationLog(cfg.log.calibrationFileName, ...
            session.phase, "", struct(), getLatestSensorTimestamp(state), ...
            commandEvent.message);
    end
    if commandEvent.startTimeAlignment
        appendTimeAlignmentLog(cfg.log.timeAlignmentFileName, ...
            "tap_capture_started", timeAlignment, commandEvent.message);
    end
    if commandEvent.resetAlignmentRuntime
        state = initLowLatencyState();
        monitor = resetMonitorAccelerationHistory(monitor);
    end
    if commandEvent.resetRuntime
        state = resetRuntimeForFormalRecording(state, session);
        trajectoryEstimator = initTrajectoryEstimator(cfg.trajectory);
        stepMetricsLogger.lastLeftStepCount = 0;
        stepMetricsLogger.lastRightStepCount = 0;
        plotState = resetAnalysisPlotState(plotState, cfg);
    end
    if commandEvent.stopRequested
        showSessionTerminalState(monitor, session);
        flushAllRuntimeLoggers(logger, decodedLoggers, rawLogger, ...
            stepMetricsLogger, trajectoryLogger);
        break;
    end

    rb = getappdata(0, cfg.queue.appdataKey);
    [rb, batch] = popMessageBatchRingBuffer(rb, cfg.loop.maxMsgsPerLoop);
    rawLoggedBatch = false;

    if cfg.loop.keepLatestPerTopicWhenBacklogged && rb.count > cfg.loop.backlogThreshold
        [rb, backlogBatch] = popMessageBatchRingBuffer(rb, rb.count);
        batch = [batch; backlogBatch]; %#ok<AGROW>
        if cfg.rawLog.enable && cfg.rawLog.logBacklogBeforeDrop
            rawLogger = appendRawBatch(rawLogger, batch, cfg, session.phase);
            rawLoggedBatch = true;
        end
        batch = keepLatestPerTopic(batch);
    end

    setappdata(0, cfg.queue.appdataKey, rb);

    if cfg.rawLog.enable && ~rawLoggedBatch
        rawLogger = appendRawBatch(rawLogger, batch, cfg, session.phase);
    end

    sensorFaultMessage = "";
    sensorFaultFoot = "";
    sensorFaultT = NaN;
    for i = 1:numel(batch)
        rawMsg = batch{i};

        try
            msg = fastDecodeMqttSensorMessage(rawMsg, cfg);
        catch ME
            state.decodeErrors = state.decodeErrors + 1;
            if strcmp(ME.identifier, 'gait:SensorFrameHeaderMismatch')
                sensorFaultFoot = inferFootFromMqttTopic(rawMsg.Topic, cfg);
                [sensorFaultT, ~] = getMqttArrivalTimestamp(rawMsg);
                sensorFaultMessage = makeSensorRestartMessage( ...
                    sensorFaultFoot, rawMsg.Topic, ME.message);
                break;
            end
            if cfg.debug.printDecodeErrors
                fprintf(2, '[DecodeError] %s\n', ME.message);
            end
            continue;
        end

        phaseAtMessage = session.phase;
        [timeAlignment, msg, alignmentEvent] = ...
            updateGatewayTimeAlignment(timeAlignment, msg, cfg.timeAlignment);
        if alignmentEvent.completed
            appendTimeAlignmentLog(cfg.log.timeAlignmentFileName, ...
                "alignment_completed", timeAlignment, alignmentEvent.message);
        end
        if ~timeAlignment.ready
            decodedLoggers = appendDecodedSensorMessage( ...
                decodedLoggers, msg, rawMsg, cfg, phaseAtMessage, false);
            continue;
        end
        [state.streamLastT, streamAccepted] = acceptSensorMessageTimestamp( ...
            state.streamLastT, msg);
        if ~streamAccepted
            state.staleFrames = state.staleFrames + 1;
        end
        decodedLoggers = appendDecodedSensorMessage( ...
            decodedLoggers, msg, rawMsg, cfg, phaseAtMessage, streamAccepted);
        if ~streamAccepted
            continue;
        end
        state = cacheLatestSensorMessage(state, msg);
        [session, calibrationEvent] = updateGaitSessionCalibration(session, msg, cfg);
        if calibrationEvent.completed
            state = synchronizeSessionCalibration(state, session, calibrationEvent.foot);
            appendGaitCalibrationLog(cfg.log.calibrationFileName, ...
                calibrationEvent.stage, calibrationEvent.foot, ...
                calibrationEvent.result, ...
                getScalarOrDefault(calibrationEvent.result, 'completedT', msg.recv_time_sec), ...
                "Calibration stage passed.");
        end

        if session.phase == "recording"
            [state, logger] = handleLowLatencyMessage(state, logger, msg, rawMsg, cfg);
        end
        if session.phase == "recording" && cfg.trajectory.enable
            trajectorySample = makeTrajectorySampleForMessage(state, msg);
            trajectoryEstimator = updateTrajectoryEstimator(trajectoryEstimator, trajectorySample, cfg.trajectory);
            stepMetricsLogger = appendStepMetricsFromEstimator(stepMetricsLogger, trajectoryEstimator, cfg);
            trajectoryLogger = appendTrajectoryStateFromEstimator(trajectoryLogger, trajectoryEstimator, msg, cfg);
        end
    end

    if strlength(sensorFaultMessage) > 0
        session.phase = "finished";
        session.recordingStopT = sensorFaultT;
        session.statusMessage = sensorFaultMessage;
        appendGaitCalibrationLog(cfg.log.calibrationFileName, ...
            "sensor_frame_fault", sensorFaultFoot, struct(), ...
            sensorFaultT, sensorFaultMessage);
        showSensorFrameFault(monitor, sensorFaultMessage);
        flushAllRuntimeLoggers(logger, decodedLoggers, rawLogger, ...
            stepMetricsLogger, trajectoryLogger);
        fprintf(2, '[SensorFrameFault] %s\n', char(sensorFaultMessage));
        break;
    end

    logger = maybeFlushLowLatencyCsvLogger(logger, cfg.log.flushEverySec);
    decodedLoggers = maybeFlushDecodedSensorLoggers(decodedLoggers, cfg);
    rawLogger = maybeFlushOptionalRawLogger(rawLogger, cfg);
    stepMetricsLogger = maybeFlushOptionalStepMetricsLogger(stepMetricsLogger, cfg);
    trajectoryLogger = maybeFlushOptionalTrajectoryStateLogger(trajectoryLogger, cfg);
    monitor = updateLatencyMonitor(monitor, state, logger, rawLogger, ...
        stepMetricsLogger, trajectoryLogger, rb, session, timeAlignment, cfg);
    plotState = updateOptionalPlots(plotState, state, trajectoryEstimator, ...
        session.phase == "recording", cfg);
    drawnow limitrate;

    if toc(lastStatTic) >= cfg.loop.statEverySec
        rb = getappdata(0, cfg.queue.appdataKey);
        fprintf(['[LL] phase=%s queue=%d dropped=%d stale=%d samples=%d rows=%d rawRows=%d ' ...
            'decodeErr=%d avgProcessingLatencyMs=%.2f loopMs=%.2f\n'], ...
            char(session.phase), rb.count, rb.dropCount, state.staleFrames, ...
            state.samplesProcessed, logger.rowsWritten, rawLogger.rowsWritten, ...
            state.decodeErrors, meanRecent(state.latencyMs), toc(loopStart) * 1000);
        lastStatTic = tic;
    end

    pause(cfg.loop.pauseSec);
end

end

function cfg = makeLowLatencyConfig()

cfg = struct();

cfg.mqtt.host = string(getenv('MEDVISION_SHOES_MQTT_HOST'));
cfg.mqtt.port = 1883;
cfg.mqtt.username = string(getenv('MEDVISION_SHOES_MQTT_USERNAME'));
cfg.mqtt.password = string(getenv('MEDVISION_SHOES_MQTT_PASSWORD'));
if any(strlength([cfg.mqtt.host, cfg.mqtt.username, cfg.mqtt.password]) == 0)
    error('Shoes:MissingMqttConfig', 'Set MEDVISION_SHOES_MQTT_HOST, MEDVISION_SHOES_MQTT_USERNAME and MEDVISION_SHOES_MQTT_PASSWORD.');
end
cfg.mqtt.clientID = "matlab_gait_low_latency";
cfg.mqtt.gatewayPreferenceGroup = 'ShoesGaitMonitor';
cfg.mqtt.leftGatewayPreference = 'LeftGatewayId';
cfg.mqtt.rightGatewayPreference = 'RightGatewayId';
leftGatewayDefault = string(getenv('MEDVISION_SHOES_LEFT_GATEWAY_ID'));
rightGatewayDefault = string(getenv('MEDVISION_SHOES_RIGHT_GATEWAY_ID'));
leftGatewayId = getGatewayPreference( ...
    cfg.mqtt.gatewayPreferenceGroup, ...
    cfg.mqtt.leftGatewayPreference, leftGatewayDefault);
rightGatewayId = getGatewayPreference( ...
    cfg.mqtt.gatewayPreferenceGroup, ...
    cfg.mqtt.rightGatewayPreference, rightGatewayDefault);
try
    cfg = configureGaitGatewayIds(cfg, leftGatewayId, rightGatewayId);
catch
    cfg = configureGaitGatewayIds( ...
        cfg, leftGatewayDefault, rightGatewayDefault);
end

cfg.queue.appdataKey = 'gait_mqtt_low_latency_ring_buffer';
cfg.queue.capacity = 5000;

% Bound one processing slice so UI commands are serviced promptly even
% after a transient graphics or disk-write stall.
cfg.loop.maxMsgsPerLoop = 120;
cfg.loop.pauseSec = 0.0005;
cfg.loop.statEverySec = 2.0;
% Keep every received frame for offline replay and parameter tuning.  IMU
% and pressure streams are processed asynchronously, so different rates are OK.
cfg.loop.keepLatestPerTopicWhenBacklogged = false;
cfg.loop.backlogThreshold = 1000;

cfg.sync.maxImuAgeSec = 0.08;

% Align both gateway clocks before calibration and formal recording. The
% left gateway is the reference; only a constant correction is applied to
% right-foot gateway timestamps.
cfg.timeAlignment.useTap = false;
cfg.timeAlignment.passiveDurationSec = 5.0;
cfg.timeAlignment.passiveMinSamplesPerFoot = 250;
cfg.timeAlignment.tapDurationSec = 8.0;
cfg.timeAlignment.tapMinPairs = 3;
cfg.timeAlignment.tapMinPeakMs2 = 3.0;
cfg.timeAlignment.tapSigmaMultiplier = 6.0;
cfg.timeAlignment.tapMinPeakSpacingSec = 0.35;
cfg.timeAlignment.tapPairArrivalToleranceSec = 0.25;
cfg.timeAlignment.tapMaxOffsetSpreadSec = 0.05;
cfg.timeAlignment.tapMaxPeaksPerFoot = 16;
cfg.timeAlignment.maxSamplesPerFoot = 3000;

cfg.calib.unloadedDurationSec = 5.0;
cfg.calib.unloadedPressureDurationSec = 3.0;
cfg.calib.unloadedMinImuSamples = 400;
cfg.calib.unloadedMinPressureSamples = 75;
cfg.calib.unloadedPressureActiveThreshold = 200;
cfg.calib.unloadedMaxActiveSensors = 3;
cfg.calib.unloadedMaxAccNormError = 0.75;
cfg.calib.unloadedMaxAngularRateDeg = 8.0;
cfg.calib.unloadedMaxAccNoise = 0.20;
cfg.calib.wornDurationSec = 2.0;
cfg.calib.wornMinImuSamples = 150;
cfg.calib.wornMinPressureSamples = 40;
cfg.calib.wornPressureActiveThreshold = 200;
cfg.calib.wornMinActiveSensors = 3;
cfg.calib.wornMinTotalPressure = 300;
cfg.calib.wornMaxPressureAgeSec = 0.08;
cfg.calib.wornMaxAccNormError = 1.0;
cfg.calib.wornMaxAngularRateDeg = 15.0;
cfg.calib.wornMaxLoadVariation = 0.25;
cfg.calib.wornMaxCopNoise = 0.12;
cfg.calib.startMaxSensorAgeSec = 0.20;

cfg.gait.heelRows = 1:3;
cfg.gait.midRows = 4:7;
cfg.gait.foreRows = 8:10;
cfg.gait.toeRows = 11:12;
cfg.gait.medialCols = 3:4;
cfg.gait.lateralCols = 1:2;
cfg.gait.contactOn = 0.30;
cfg.gait.contactOff = 0.10;
cfg.gait.activeSensorContactEnable = true;
cfg.gait.activePressureThreshold = 200;
cfg.gait.activeSensorsOn = 4;
cfg.gait.activeSensorsOff = 3;
cfg.gait.heelOffHeelRatio = 0.20;
cfg.gait.heelOffForeToeRatio = 0.35;
cfg.gait.pushOffForeToeRatio = 0.55;
cfg.gait.pushOffCOPy = 0.65;
cfg.gait.zuptMinLoad = 0.15;
cfg.gait.zuptMinContactDuration = 0.08;
cfg.gait.zuptMaxAbsDLoad = 3.0;
cfg.gait.zuptMaxAbsDCOPy = 8.0;
cfg.gait.accBiasAdaptGain = 0.02;
cfg.gait.maxIntegrationDt = 0.05;
cfg.gait.maxFootSpeed = 3.0;

cfg.log.fileName = 'gait_state.csv';
cfg.log.manifestFileName = 'session_manifest.txt';
cfg.log.manualTemplateFileName = 'manual_steps_template.csv';
cfg.log.calibrationFileName = 'calibration.csv';
cfg.log.timeAlignmentFileName = 'time_alignment.csv';
cfg.log.flushEverySec = 0.25;
cfg.log.flushEveryRows = 80;
cfg.log.includePressureValues = true;
cfg.log.pressureActiveThreshold = 20;

cfg.decodedLog.imuFileName = 'imu_decoded.csv';
cfg.decodedLog.pressureFileName = 'pressure_decoded.csv';
cfg.decodedLog.flushEverySec = 0.25;
cfg.decodedLog.flushEveryRows = 100;

% Optional heavy features.  Keep these false to measure the low-latency
% baseline, then enable one at a time to see which feature adds delay.
cfg.rawLog.enable = true;
cfg.rawLog.fileName = 'raw_mqtt_low_latency.csv';
cfg.rawLog.flushEverySec = 0.5;
cfg.rawLog.flushEveryRows = 200;
cfg.rawLog.logBacklogBeforeDrop = true;

cfg.plot.fullPressureEnable = true;
cfg.plot.fullPressureRefreshEverySec = 0.20;
cfg.plot.pressureMode = "fast";  % "fast" uses imagesc; "full" uses patch/label insole plot.
cfg.plot.imuEnable = true;
cfg.plot.imuRefreshEverySec = 0.20;
cfg.plot.imuMode = "fast";       % "fast" uses compact lines; "full" uses updateRealtimeImuFigure.
cfg.plot.fastImuMaxPoints = 250;

cfg.zupt.pressureOnThreshold = 0.30;
cfg.zupt.pressureOffThreshold = 0.10;
cfg.zupt.minStanceDurationMs = 30;
cfg.zupt.minSwingDurationMs = 30;
cfg.zupt.debounceMs = 0;
cfg.zupt.maxSwingDurationMs = 1500;
cfg.zupt.useHeelToToeAsRequired = false;
cfg.zupt.activeSensorContactEnable = true;
cfg.zupt.activePressureThreshold = 200;
cfg.zupt.activeSensorsOn = 4;
cfg.zupt.activeSensorsOff = 3;

cfg.traj.accUnit = "g";
cfg.traj.gravityCompensation = "bodyThenWorld";
cfg.traj.maxDt = 0.15;
cfg.traj.minDt = 1e-4;
cfg.traj.maxReasonableStepLength = 1.5;

cfg.trajectory.enable = true;
cfg.trajectory.figureEnable = true;
cfg.trajectory.figureRefreshEverySec = 0.10;
cfg.trajectory.stepMetricsFigureEnable = true;
cfg.trajectory.stepMetricsMaxPoints = 100;
cfg.trajectory.stepMetricsLogEnable = true;
cfg.trajectory.stepMetricsLogFileName = 'step_metrics.csv';
cfg.trajectory.stepMetricsLogFlushEverySec = 0.5;
cfg.trajectory.stepMetricsLogFlushEveryRows = 20;
cfg.trajectory.stateLogEnable = true;
cfg.trajectory.stateLogFileName = 'trajectory_state.csv';
cfg.trajectory.stateLogFlushEverySec = 0.5;
cfg.trajectory.stateLogFlushEveryRows = 80;
cfg.trajectory.contactOn = cfg.zupt.pressureOnThreshold;
cfg.trajectory.contactOff = cfg.zupt.pressureOffThreshold;
cfg.trajectory.pressureOnThreshold = cfg.zupt.pressureOnThreshold;
cfg.trajectory.pressureOffThreshold = cfg.zupt.pressureOffThreshold;
cfg.trajectory.minStanceDurationMs = cfg.zupt.minStanceDurationMs;
cfg.trajectory.minSwingDurationMs = cfg.zupt.minSwingDurationMs;
cfg.trajectory.debounceMs = cfg.zupt.debounceMs;
cfg.trajectory.maxSwingDurationMs = cfg.zupt.maxSwingDurationMs;
cfg.trajectory.useHeelToToeAsRequired = cfg.zupt.useHeelToToeAsRequired;
cfg.trajectory.pressureOn = 300;
cfg.trajectory.pressureOff = 150;
cfg.trajectory.maxDt = cfg.traj.maxDt;
cfg.trajectory.minDt = cfg.traj.minDt;
cfg.trajectory.maxSpeed = 4.0;
cfg.trajectory.maxReasonableStepLength = cfg.traj.maxReasonableStepLength;
cfg.trajectory.biasAdaptGain = 0.01;
cfg.trajectory.activeSensorContactEnable = cfg.zupt.activeSensorContactEnable;
cfg.trajectory.activePressureThreshold = cfg.zupt.activePressureThreshold;
cfg.trajectory.activeSensorsOn = cfg.zupt.activeSensorsOn;
cfg.trajectory.activeSensorsOff = cfg.zupt.activeSensorsOff;
cfg.trajectory.landingVelocityCorrectionGain = 1.5;
cfg.trajectory.maxLandingCorrection = 2.0;
cfg.trajectory.verticalFloorTolerance = 0.02;
cfg.trajectory.maxCorrectedVerticalExcursion = 0.35;
cfg.trajectory.provisionalVerticalFloorTolerance = 0.08;
cfg.trajectory.maxProvisionalVerticalExcursion = 0.50;
cfg.trajectory.maxSwingHistorySamples = 400;
cfg.trajectory.initialVerticalSwingBias.left = 0;
cfg.trajectory.initialVerticalSwingBias.right = 0;
cfg.trajectory.verticalSwingBiasAdaptGain = 0.08;
cfg.trajectory.maxVerticalSwingBias = 2.0;
cfg.trajectory.verticalBiasMinSwingDuration = 0.25;
cfg.trajectory.verticalBiasMaxSwingDuration = 1.50;
cfg.trajectory.maxVerticalBiasResidual = 1.0;
cfg.trajectory.gravity = 9.80665;
cfg.trajectory.quatDirection = "bodyToWorld";
cfg.trajectory.gravityRemovalMode = cfg.traj.gravityCompensation;
cfg.trajectory.accUnit = cfg.traj.accUnit;
cfg.trajectory.alignHeadingToCalibration = true;
cfg.trajectory.headingOffsetDeg.left = -79;
cfg.trajectory.headingOffsetDeg.right = -99;
cfg.trajectory.useVertical = true;
cfg.trajectory.lockVerticalOnContact = true;
cfg.trajectory.groundZ = 0;
cfg.trajectory.accDeadband = 0.15;
cfg.trajectory.axisLimit = [-2 2 -2 2 -0.5 1.5];
cfg.trajectory.centerOn = "right";
cfg.trajectory.maxPoints = 1000;

cfg.monitor.enable = true;
cfg.monitor.refreshEverySec = 0.20;
cfg.monitor.warnLatencyMs = 30;
cfg.monitor.warnQueue = 50;
cfg.monitor.accelMaxPoints = 250;
cfg.monitor.accelYLim = [0 3];
cfg.monitor.pressureCLim = [0 1300];

cfg.debug.printDecodeErrors = false;
cfg.debug.enableGaitDebug = false;
cfg.debug.plotPressureStateEvents = false;

cfg.control.appdataKey = 'gait_low_latency_session_command';

end

function value = getGatewayPreference(groupName, preferenceName, defaultValue)

value = string(defaultValue);
try
    if ispref(groupName, preferenceName)
        savedValue = string(getpref(groupName, preferenceName));
        if isscalar(savedValue) && ~ismissing(savedValue) && strlength(savedValue) > 0
            value = savedValue;
        end
    end
catch
    value = string(defaultValue);
end

end

function method = timeAlignmentMethodName(useTap)

if useTap
    method = "tap";
else
    method = "passive";
end

end

function writeSessionManifest(cfg)

fid = fopen(cfg.log.manifestFileName, 'w');
if fid < 0
    warning('Cannot open session manifest file: %s', cfg.log.manifestFileName);
    return;
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

fprintf(fid, 'session_stamp,%s\n', cfg.log.sessionStamp);
fprintf(fid, 'start_datetime,%s\n', char(cfg.log.startDateTime, 'yyyy-MM-dd HH:mm:ss.SSS'));
fprintf(fid, 'session_directory,%s\n', cfg.log.sessionDir);
fprintf(fid, 'gait_state_csv,%s\n', cfg.log.fileName);
fprintf(fid, 'imu_decoded_csv,%s\n', cfg.decodedLog.imuFileName);
fprintf(fid, 'pressure_decoded_csv,%s\n', cfg.decodedLog.pressureFileName);
fprintf(fid, 'raw_mqtt_csv,%s\n', cfg.rawLog.fileName);
fprintf(fid, 'step_metrics_csv,%s\n', cfg.trajectory.stepMetricsLogFileName);
fprintf(fid, 'trajectory_state_csv,%s\n', cfg.trajectory.stateLogFileName);
fprintf(fid, 'manual_steps_template_csv,%s\n', cfg.log.manualTemplateFileName);
fprintf(fid, 'calibration_csv,%s\n', cfg.log.calibrationFileName);
fprintf(fid, 'time_alignment_csv,%s\n', cfg.log.timeAlignmentFileName);
fprintf(fid, ...
    'workflow,gateway_time_alignment_then_empty_shoe_then_worn_standing_then_recording\n');
fprintf(fid, 'raw_and_decoded_logs_include_calibration,1\n');
fprintf(fid, 'formal_metric_logs_recording_phase_only,1\n');
fprintf(fid, 'sample_time_basis,aligned_gateway_timestamp\n');
fprintf(fid, 'time_alignment.reference_foot,left\n');
fprintf(fid, 'time_alignment.requested_method,%s\n', ...
    char(timeAlignmentMethodName(cfg.timeAlignment.useTap)));
fprintf(fid, 'mqtt.left_gateway_id,%s\n', char(cfg.mqtt.gatewayIds.left));
fprintf(fid, 'mqtt.right_gateway_id,%s\n', char(cfg.mqtt.gatewayIds.right));
fprintf(fid, 'mqtt.left_imu_topic,%s\n', char(cfg.mqtt.topics.leftImu));
fprintf(fid, 'mqtt.right_imu_topic,%s\n', char(cfg.mqtt.topics.rightImu));
fprintf(fid, 'mqtt.left_pressure_topic,%s\n', char(cfg.mqtt.topics.leftPressure));
fprintf(fid, 'mqtt.right_pressure_topic,%s\n', char(cfg.mqtt.topics.rightPressure));
fprintf(fid, '\n[manual_step_annotation_template]\n');
fprintf(fid, 'trial_id,foot,step_index,true_step_length_m,lift_time,land_time,notes\n');
fprintf(fid, '\n[key_parameters]\n');
fprintf(fid, 'sync.maxImuAgeSec,%.6g\n', cfg.sync.maxImuAgeSec);
fprintf(fid, 'timeAlignment.passiveDurationSec,%.6g\n', ...
    cfg.timeAlignment.passiveDurationSec);
fprintf(fid, 'timeAlignment.passiveMinSamplesPerFoot,%d\n', ...
    cfg.timeAlignment.passiveMinSamplesPerFoot);
fprintf(fid, 'timeAlignment.tapDurationSec,%.6g\n', ...
    cfg.timeAlignment.tapDurationSec);
fprintf(fid, 'timeAlignment.tapMinPairs,%d\n', ...
    cfg.timeAlignment.tapMinPairs);
fprintf(fid, 'timeAlignment.tapMinPeakMs2,%.6g\n', ...
    cfg.timeAlignment.tapMinPeakMs2);
fprintf(fid, 'timeAlignment.tapSigmaMultiplier,%.6g\n', ...
    cfg.timeAlignment.tapSigmaMultiplier);
fprintf(fid, 'timeAlignment.tapMinPeakSpacingSec,%.6g\n', ...
    cfg.timeAlignment.tapMinPeakSpacingSec);
fprintf(fid, 'timeAlignment.tapPairArrivalToleranceSec,%.6g\n', ...
    cfg.timeAlignment.tapPairArrivalToleranceSec);
fprintf(fid, 'timeAlignment.tapMaxOffsetSpreadSec,%.6g\n', ...
    cfg.timeAlignment.tapMaxOffsetSpreadSec);
fprintf(fid, 'gait.contactOn,%.6g\n', cfg.gait.contactOn);
fprintf(fid, 'gait.contactOff,%.6g\n', cfg.gait.contactOff);
fprintf(fid, 'gait.activeSensorContactEnable,%d\n', cfg.gait.activeSensorContactEnable);
fprintf(fid, 'gait.activePressureThreshold,%.6g\n', cfg.gait.activePressureThreshold);
fprintf(fid, 'gait.activeSensorsOn,%d\n', cfg.gait.activeSensorsOn);
fprintf(fid, 'gait.activeSensorsOff,%d\n', cfg.gait.activeSensorsOff);
fprintf(fid, 'gait.zuptMinLoad,%.6g\n', cfg.gait.zuptMinLoad);
fprintf(fid, 'gait.zuptMinContactDuration,%.6g\n', cfg.gait.zuptMinContactDuration);
fprintf(fid, 'gait.zuptMaxAbsDLoad,%.6g\n', cfg.gait.zuptMaxAbsDLoad);
fprintf(fid, 'gait.zuptMaxAbsDCOPy,%.6g\n', cfg.gait.zuptMaxAbsDCOPy);
fprintf(fid, 'log.pressureActiveThreshold,%.6g\n', cfg.log.pressureActiveThreshold);
fprintf(fid, 'calib.unloadedDurationSec,%.6g\n', cfg.calib.unloadedDurationSec);
fprintf(fid, 'calib.unloadedMinImuSamples,%d\n', cfg.calib.unloadedMinImuSamples);
fprintf(fid, 'calib.unloadedMinPressureSamples,%d\n', cfg.calib.unloadedMinPressureSamples);
fprintf(fid, 'calib.unloadedMaxAccNoise,%.6g\n', cfg.calib.unloadedMaxAccNoise);
fprintf(fid, 'calib.wornDurationSec,%.6g\n', cfg.calib.wornDurationSec);
fprintf(fid, 'calib.wornMinImuSamples,%d\n', cfg.calib.wornMinImuSamples);
fprintf(fid, 'calib.wornMinPressureSamples,%d\n', cfg.calib.wornMinPressureSamples);
fprintf(fid, 'calib.wornMaxLoadVariation,%.6g\n', cfg.calib.wornMaxLoadVariation);
fprintf(fid, 'calib.startMaxSensorAgeSec,%.6g\n', cfg.calib.startMaxSensorAgeSec);
fprintf(fid, 'trajectory.pressureOnThreshold,%.6g\n', cfg.trajectory.pressureOnThreshold);
fprintf(fid, 'trajectory.pressureOffThreshold,%.6g\n', cfg.trajectory.pressureOffThreshold);
fprintf(fid, 'trajectory.debounceMs,%.6g\n', cfg.trajectory.debounceMs);
fprintf(fid, 'trajectory.minStanceDurationMs,%.6g\n', cfg.trajectory.minStanceDurationMs);
fprintf(fid, 'trajectory.minSwingDurationMs,%.6g\n', cfg.trajectory.minSwingDurationMs);
fprintf(fid, 'trajectory.maxDt,%.6g\n', cfg.trajectory.maxDt);
fprintf(fid, 'trajectory.accDeadband,%.6g\n', cfg.trajectory.accDeadband);
fprintf(fid, 'trajectory.biasAdaptGain,%.6g\n', cfg.trajectory.biasAdaptGain);
fprintf(fid, 'trajectory.activeSensorContactEnable,%d\n', cfg.trajectory.activeSensorContactEnable);
fprintf(fid, 'trajectory.activePressureThreshold,%.6g\n', cfg.trajectory.activePressureThreshold);
fprintf(fid, 'trajectory.activeSensorsOn,%d\n', cfg.trajectory.activeSensorsOn);
fprintf(fid, 'trajectory.activeSensorsOff,%d\n', cfg.trajectory.activeSensorsOff);
fprintf(fid, 'trajectory.landingVelocityCorrectionGain,%.6g\n', cfg.trajectory.landingVelocityCorrectionGain);
fprintf(fid, 'trajectory.maxLandingCorrection,%.6g\n', cfg.trajectory.maxLandingCorrection);
fprintf(fid, 'trajectory.verticalFloorTolerance,%.6g\n', cfg.trajectory.verticalFloorTolerance);
fprintf(fid, 'trajectory.maxCorrectedVerticalExcursion,%.6g\n', cfg.trajectory.maxCorrectedVerticalExcursion);
fprintf(fid, 'trajectory.provisionalVerticalFloorTolerance,%.6g\n', cfg.trajectory.provisionalVerticalFloorTolerance);
fprintf(fid, 'trajectory.maxProvisionalVerticalExcursion,%.6g\n', cfg.trajectory.maxProvisionalVerticalExcursion);
fprintf(fid, 'trajectory.initialVerticalSwingBias.left,%.6g\n', cfg.trajectory.initialVerticalSwingBias.left);
fprintf(fid, 'trajectory.initialVerticalSwingBias.right,%.6g\n', cfg.trajectory.initialVerticalSwingBias.right);
fprintf(fid, 'trajectory.verticalSwingBiasAdaptGain,%.6g\n', cfg.trajectory.verticalSwingBiasAdaptGain);
fprintf(fid, 'trajectory.maxVerticalSwingBias,%.6g\n', cfg.trajectory.maxVerticalSwingBias);
fprintf(fid, 'trajectory.verticalBiasMinSwingDuration,%.6g\n', cfg.trajectory.verticalBiasMinSwingDuration);
fprintf(fid, 'trajectory.verticalBiasMaxSwingDuration,%.6g\n', cfg.trajectory.verticalBiasMaxSwingDuration);
fprintf(fid, 'trajectory.maxVerticalBiasResidual,%.6g\n', cfg.trajectory.maxVerticalBiasResidual);
fprintf(fid, 'trajectory.alignHeadingToCalibration,%d\n', cfg.trajectory.alignHeadingToCalibration);
fprintf(fid, 'trajectory.headingOffsetDeg.left,%.6g\n', cfg.trajectory.headingOffsetDeg.left);
fprintf(fid, 'trajectory.headingOffsetDeg.right,%.6g\n', cfg.trajectory.headingOffsetDeg.right);
fprintf(fid, 'trajectory.gravityRemovalMode,%s\n', char(cfg.trajectory.gravityRemovalMode));
fprintf(fid, 'trajectory.accUnit,%s\n', char(cfg.trajectory.accUnit));

writeManualStepsTemplate(cfg.log.manualTemplateFileName, cfg.log.sessionStamp);

end

function writeManualStepsTemplate(fileName, sessionStamp)

fid = fopen(fileName, 'w');
if fid < 0
    warning('Cannot open manual steps template file: %s', fileName);
    return;
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

fprintf(fid, 'session_stamp,trial_id,foot,step_index,true_step_length_m,lift_time,land_time,notes\n');
fprintf(fid, '%s,walk01,left,1,,,,\n', sessionStamp);
fprintf(fid, '%s,walk01,right,1,,,,\n', sessionStamp);

end

function state = initLowLatencyState()

state = struct();
state.left = initFootRuntimeState();
state.right = initFootRuntimeState();
state.stepCount = 0;
state.samplesProcessed = 0;
state.decodeErrors = 0;
state.staleFrames = 0;
state.streamLastT = struct();
state.latencyMs = nan(1, 100);
state.latencyCursor = 0;

end

function s = initFootRuntimeState()

s = struct();
s.latestImu = [];
s.latestImuT = NaN;
s.latestPressure = nan(1, 48);
s.latestPressureT = NaN;
s.calibCount = 0;
s.calibrated = false;
s.calib = [];
s.gait = initOneFootGaitState();
s.lastGait = [];

end

function [session, timeAlignment, event] = consumeSessionCommand( ...
        session, state, timeAlignment, cfg)

event = struct( ...
    'accepted', false, ...
    'resetRuntime', false, ...
    'stopRequested', false, ...
    'startTimeAlignment', false, ...
    'resetAlignmentRuntime', false, ...
    'message', "");
if ~isappdata(0, cfg.control.appdataKey)
    return;
end

command = string(getappdata(0, cfg.control.appdataKey));
if strlength(command) == 0
    return;
end
setappdata(0, cfg.control.appdataKey, '');

if command == "start_time_alignment"
    if session.phase ~= "waiting_unloaded"
        event.message = "Time alignment can only run before empty-shoe calibration.";
        session.statusMessage = event.message;
        return;
    end
    if timeAlignment.mode ~= "tap"
        event.message = ...
            "请先勾选“启用硬板敲击”，再连接 MQTT 并开始敲击对齐。";
        session.statusMessage = event.message;
        return;
    end
    timeAlignment = startGatewayTapAlignment(timeAlignment);
    event.accepted = true;
    event.startTimeAlignment = true;
    event.resetAlignmentRuntime = true;
    event.message = timeAlignment.statusMessage;
    session.statusMessage = event.message;
    return;
end

if command == "start_unloaded" && ~timeAlignment.ready
    event.message = ...
        "Start blocked: wait until left/right gateway time alignment is ready.";
    session.statusMessage = event.message;
    return;
end

if command == "start_recording" && ~isFormalStartPostureValid(state, cfg)
    event.message = ...
        "Start blocked: keep both feet supported and confirm all four sensor streams are current.";
    session.statusMessage = event.message;
    return;
end

[session, phaseEvent] = startGaitSessionPhase( ...
    session, command, getLatestSensorTimestamp(state));
event.accepted = phaseEvent.accepted;
event.resetRuntime = phaseEvent.resetRuntime;
event.stopRequested = phaseEvent.stopRequested;
event.message = phaseEvent.message;
if ~event.accepted
    session.statusMessage = event.message;
end

end

function ok = isFormalStartPostureValid(state, cfg)

ok = true;
latestT = getLatestSensorTimestamp(state);
if ~isfinite(latestT)
    ok = false;
    return;
end

for sideCell = {'left', 'right'}
    foot = state.(sideCell{1});
    pressure = double(foot.latestPressure(:).');
    hasContact = numel(pressure) == 48 && ...
        sum(pressure > cfg.calib.wornPressureActiveThreshold) >= ...
            cfg.calib.wornMinActiveSensors && ...
        sum(pressure) >= cfg.calib.wornMinTotalPressure;
    times = [foot.latestImuT foot.latestPressureT];
    streamsCurrent = all(isfinite(times)) && ...
        all(abs(latestT - times) <= cfg.calib.startMaxSensorAgeSec);
    ok = ok && hasContact && streamsCurrent;
end

end

function state = cacheLatestSensorMessage(state, msg)

side = char(msg.foot);
if ~isfield(state, side)
    return;
end

foot = state.(side);
if strcmp(msg.sensor_type, 'imu')
    foot.latestImu = msg;
    foot.latestImuT = msg.recv_time_sec;
elseif strcmp(msg.sensor_type, 'pressure')
    P = double(msg.data.values(:).');
    P(~isfinite(P)) = 0;
    P = correctPressureValues(P, getFieldOrDefault(foot, 'calib', struct()));
    foot.latestPressure = P;
    foot.latestPressureT = msg.recv_time_sec;
end
state.(side) = foot;

end

function P = correctPressureValues(P, calib)

P = double(P(:).');
if isstruct(calib) && isfield(calib, 'pressureZero') && ...
        numel(calib.pressureZero) >= numel(P)
    pressureZero = double(calib.pressureZero(1:numel(P)));
    P = P - pressureZero(:).';
end
P(~isfinite(P)) = 0;
P = max(P, 0);

end

function state = synchronizeSessionCalibration(state, session, sideValue)

side = char(sideValue);
if ~isfield(state, side) || ~isfield(session.calibration, side)
    return;
end

calib = session.calibration.(side);
state.(side).calib = calib;
state.(side).calibCount = getScalarOrDefault(calib, 'imuSamples', 0);
state.(side).calibrated = session.worn.(side).complete;
if state.(side).calibrated
    state.(side).gait = makeCalibratedGaitState(calib);
end

end

function state = resetRuntimeForFormalRecording(state, session)

oldState = state;
state = initLowLatencyState();
state.decodeErrors = oldState.decodeErrors;
state.staleFrames = oldState.staleFrames;
state.streamLastT = oldState.streamLastT;

for sideCell = {'left', 'right'}
    side = sideCell{1};
    state.(side).latestImu = oldState.(side).latestImu;
    state.(side).latestImuT = oldState.(side).latestImuT;
    state.(side).latestPressure = oldState.(side).latestPressure;
    state.(side).latestPressureT = oldState.(side).latestPressureT;
    state.(side).calib = session.calibration.(side);
    state.(side).calibCount = getScalarOrDefault( ...
        session.calibration.(side), 'imuSamples', 0);
    state.(side).calibrated = true;
    state.(side).gait = makeCalibratedGaitState(session.calibration.(side));
end

end

function gait = makeCalibratedGaitState(calib)

gait = initOneFootGaitState();
gait.accBias = getVectorOrDefault(calib, 'accNavBias', [0 0 0]);
gait.q0_wxyz = getVectorOrDefault(calib, 'q0_wxyz', [1 0 0 0]);
standingCop = getVectorOrDefault(calib, 'standingCOP', [0 0]);
gait.lastCOPyNorm = standingCop(2);

end

function plotState = resetAnalysisPlotState(plotState, cfg)

if cfg.trajectory.figureEnable
    plotState.trajectory = resetTrajectoryFigureData( ...
        plotState.trajectory, cfg.trajectory);
end
if cfg.trajectory.stepMetricsFigureEnable
    plotState.stepMetrics = resetStepMetricsFigureData( ...
        plotState.stepMetrics, ...
        struct('maxPoints', cfg.trajectory.stepMetricsMaxPoints));
end
plotState.lastTrajectoryPlotTime = tic;

end

function [logger, decodedLoggers, rawLogger, stepMetricsLogger, trajectoryLogger] = ...
        flushAllRuntimeLoggers(logger, decodedLoggers, rawLogger, ...
        stepMetricsLogger, trajectoryLogger)

logger = flushLowLatencyCsvLogger(logger);
decodedLoggers.imu = flushOneDecodedSensorLogger(decodedLoggers.imu);
decodedLoggers.pressure = flushOneDecodedSensorLogger(decodedLoggers.pressure);
rawLogger = flushOptionalRawLogger(rawLogger);
stepMetricsLogger = flushOptionalStepMetricsLogger(stepMetricsLogger);
trajectoryLogger = flushOptionalTrajectoryStateLogger(trajectoryLogger);

end

function s = initOneFootGaitState()

s = struct();
s.contact = true;
s.lastContact = true;
s.lastHeelOff = false;
s.lastPushOff = false;
s.lastHS_time = -inf;
s.contactStartT = NaN;
s.lastLoadIndex = 1.0;
s.lastCOPyNorm = 0.0;
s.lastT = [];
s.stepCount = 0;
s.vel = [0 0 0];
s.pos = [0 0 0];
s.accBias = [0 0 0];
s.q0_wxyz = [1 0 0 0];
s.gyroBias_dps = [0 0 0];

end

function lowLatencyMqttCallback(topic, msg, appdataKey, runtimeTic)

rb = getappdata(0, appdataKey);
if isempty(rb)
    rb = initMessageRingBuffer(1000);
end

item = struct();
item.Topic = topic;
item.Data = msg;
item.ArrivalT = toc(runtimeTic);
item.RuntimeTic = runtimeTic;
arrivalDt = datetime('now', 'TimeZone', 'local', ...
    'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
item.ArrivalEpochSec = posixtime(arrivalDt);
item.ArrivalTimeStr = char(arrivalDt);

rb = pushMessageRingBuffer(rb, item);
setappdata(0, appdataKey, rb);

end

function msg = fastDecodeMqttSensorMessage(rawMsg, cfg)

[bytes, gatewayTimeSec, gatewayTimeStr] = fastPayloadToBytes(rawMsg.Data);

rawTopic = string(rawMsg.Topic);
parts = split(rawTopic, "/");
if numel(parts) ~= 4
    error('Bad topic format: %s', char(rawTopic));
end

topicType = parts(3);
deviceId = parts(4);
foot = lookupFootFast(deviceId, cfg);

if topicType == "1"
    sensorType = "imu";
elseif topicType == "0"
    sensorType = "pressure";
else
    error('Unknown topic type: %s', char(topicType));
end
validateMqttSensorFrameHeader(bytes, foot, sensorType);

if sensorType == "imu"
    data = decodeIMUFrame(bytes);
else
    data = decodePressureFrame(bytes);
end

msg = struct();
msg.foot = char(foot);
msg.sensor_type = char(sensorType);
msg.data = data;
[arrivalSec, arrivalTimeStr] = getMqttArrivalTimestamp(rawMsg);
msg.recv_time_sec = gatewayTimeSec;
msg.recv_time_str = gatewayTimeStr;
msg.arrival_time_sec = arrivalSec;
msg.arrival_time_str = arrivalTimeStr;
msg.gateway_time_sec = gatewayTimeSec;
msg.gateway_time_str = gatewayTimeStr;
msg.sensor_time_sec = gatewayTimeSec;
msg.topic = rawTopic;

end

function [bytes, sensorTimeSec, sensorTimeStr] = fastPayloadToBytes(payload)

if isa(payload, 'uint8')
    payload = char(payload(:).');
elseif isstring(payload)
    payload = char(payload);
end

payload = strrep(payload, char(0), '');
payload = strrep(payload, char(65279), '');

sensorTimeSec = NaN;
sensorTimeStr = "";
lb = find(payload == '[', 1, 'first');
rb = find(payload == ']', 1, 'first');

if isempty(rb)
    hexPart = payload;
else
    if ~isempty(lb) && rb > lb
        sensorTimeStr = string(strtrim(payload(lb + 1:rb - 1)));
        sensorTimeSec = parseSensorTimestampSec(sensorTimeStr);
    end
    hexPart = payload(rb + 1:end);
end

hexPart = upper(hexPart);
isHex = (hexPart >= '0' & hexPart <= '9') | (hexPart >= 'A' & hexPart <= 'F');
hexClean = hexPart(isHex);

if mod(numel(hexClean), 2) ~= 0
    error('Odd HEX payload length: %d', numel(hexClean));
end

bytes = uint8(sscanf(hexClean, '%2x').');

end

function tSec = parseSensorTimestampSec(sensorTimeStr)

tSec = NaN;
if strlength(sensorTimeStr) == 0
    return;
end

try
    dt = datetime(char(sensorTimeStr), 'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSS');
    tSec = posixtime(dt);
catch
    try
        dt = datetime(char(sensorTimeStr));
        tSec = posixtime(dt);
    catch
        tSec = NaN;
    end
end

end

function foot = lookupFootFast(deviceId, cfg)

deviceId = string(deviceId);
for i = 1:numel(cfg.devices)
    if string(cfg.devices(i).id) == deviceId
        foot = string(cfg.devices(i).foot);
        return;
    end
end

error('Unknown device id: %s', char(deviceId));

end

function foot = inferFootFromMqttTopic(topic, cfg)

foot = "";
parts = split(string(topic), "/");
if numel(parts) ~= 4
    return;
end

try
    foot = lookupFootFast(parts(4), cfg);
catch
    foot = "";
end

end

function message = makeSensorRestartMessage(foot, topic, detail)

switch string(foot)
    case "left"
        footLabel = "左脚";
    case "right"
        footLabel = "右脚";
    otherwise
        footLabel = "对应";
end

message = string(sprintf([ ...
    '检测到%s鞋传感器 payload 帧头异常。\n' ...
    'Topic: %s\n%s\n\n' ...
    '请手动重启%s鞋子，然后关闭并重新启动本程序，' ...
    '重新执行不穿鞋校准、穿鞋站立准备和正式采集。' ...
    '当前会话已停止，已有原始日志已保留。'], ...
    char(footLabel), char(string(topic)), char(string(detail)), ...
    char(footLabel)));

end

function [state, logger] = handleLowLatencyMessage(state, logger, msg, rawMsg, cfg)

footName = msg.foot;
foot = state.(footName);

if strcmp(msg.sensor_type, 'imu')
    foot.latestImu = msg;
    foot.latestImuT = msg.recv_time_sec;
    state.(footName) = foot;
    return;
end

if ~strcmp(msg.sensor_type, 'pressure')
    return;
end

imuAgeSec = NaN;
imuDataForGait = struct();
if ~isempty(foot.latestImu)
    candidateAgeSec = msg.recv_time_sec - foot.latestImuT;
    if isfinite(candidateAgeSec) && abs(candidateAgeSec) <= cfg.sync.maxImuAgeSec
        imuAgeSec = candidateAgeSec;
        imuDataForGait = foot.latestImu.data;
    end
end

P = double(msg.data.values(:).');
P = correctPressureValues(P, getFieldOrDefault(foot, 'calib', struct()));
foot.latestPressure = P;
foot.latestPressureT = msg.recv_time_sec;

if ~foot.calibrated
    state.(footName) = foot;
    return;
end

[g, foot.gait] = updateOneFootLowLatency(P, imuDataForGait, msg.recv_time_sec, foot.gait, cfg.gait, foot.calib);
foot.lastGait = g;
state.(footName) = foot;

if g.heelStrike
    state.stepCount = state.stepCount + 1;
end

state.samplesProcessed = state.samplesProcessed + 1;

% Processing latency uses the callback clock. Motion analysis uses the
% aligned gateway timestamp carried in msg.recv_time_sec.
latencyMs = getProcessingLatencyMs(rawMsg);
state.latencyCursor = mod(state.latencyCursor, numel(state.latencyMs)) + 1;
state.latencyMs(state.latencyCursor) = latencyMs;

row = makeLowLatencyPressureCsvRow(msg, footName, imuAgeSec, latencyMs, ...
    P, g, state, cfg.log.includePressureValues);
logger = appendLowLatencyCsvRow(logger, row, cfg);

end

function [g, s] = updateOneFootLowLatency(P, imuData, t, s, cfg, calib)

if ~isfield(s, 'contactStartT')
    s.contactStartT = NaN;
end

region = computePressureRegions48(P, cfg);

if isempty(s.lastT)
    dt = 0;
else
    dt = max(1e-4, min(t - s.lastT, cfg.maxIntegrationDt));
end
s.lastT = t;

loadIndex = region.total / max(calib.standingTotalPressure, 1e-6);

if region.total > 1e-6
    R_heel = region.heel / region.total;
    R_mid = region.mid / region.total;
    R_fore = region.fore / region.total;
    R_toe = region.toe / region.total;
    R_medial = region.medial / region.total;
    R_lateral = region.lateral / region.total;
else
    R_heel = 0; R_mid = 0; R_fore = 0; R_toe = 0; R_medial = 0; R_lateral = 0;
end

foreToeRatio = R_fore + R_toe;

s.lastContact = s.contact;
activeSensorCount = sum(P > cfg.activePressureThreshold);
if ~s.contact && (loadIndex > cfg.contactOn || ...
        (cfg.activeSensorContactEnable && activeSensorCount >= cfg.activeSensorsOn))
    s.contact = true;
elseif s.contact && (loadIndex <= cfg.contactOff || ...
        (cfg.activeSensorContactEnable && activeSensorCount < cfg.activeSensorsOff))
    s.contact = false;
end

heelStrike = false;
toeOff = false;
heelOff = false;
pushOff = false;

if ~s.lastContact && s.contact
    heelStrike = true;
    s.lastHS_time = t;
    s.contactStartT = t;
    s.lastHeelOff = false;
    s.lastPushOff = false;
    s.stepCount = s.stepCount + 1;
end

if s.lastContact && ~s.contact
    toeOff = true;
    s.contactStartT = NaN;
    s.lastHeelOff = false;
    s.lastPushOff = false;
end

if s.contact && ~isfinite(s.contactStartT)
    s.contactStartT = t;
end

timeAfterHS = t - s.lastHS_time;
contactDuration = t - s.contactStartT;

if s.contact && ~s.lastHeelOff && timeAfterHS > 0.12
    if R_heel < cfg.heelOffHeelRatio && foreToeRatio > cfg.heelOffForeToeRatio
        heelOff = true;
        s.lastHeelOff = true;
    end
end

if s.contact && ~s.lastPushOff && timeAfterHS > 0.15
    if foreToeRatio > cfg.pushOffForeToeRatio && region.copYNorm > cfg.pushOffCOPy
        pushOff = true;
        s.lastPushOff = true;
    end
end

if dt > 0
    dLoad = (loadIndex - s.lastLoadIndex) / dt;
    dCOPy = (region.copYNorm - s.lastCOPyNorm) / dt;
else
    dLoad = 0;
    dCOPy = 0;
end

zuptActive = s.contact && loadIndex > cfg.zuptMinLoad && ...
    contactDuration > cfg.zuptMinContactDuration && ...
    abs(dLoad) < cfg.zuptMaxAbsDLoad && abs(dCOPy) < cfg.zuptMaxAbsDCOPy;

q = getQuaternionOrDefault(imuData, s.q0_wxyz);
accBody = getVectorOrDefault(imuData, 'acc_g', [0 0 1]) * 9.80665;
bodyAccBias = getVectorOrDefault(calib, 'bodyAccBias', [0 0 0]);
accNavRaw = quatRotateVectorWxyz(q, accBody - bodyAccBias) - [0 0 9.80665];

if zuptActive
    s.accBias = (1 - cfg.accBiasAdaptGain) * s.accBias + cfg.accBiasAdaptGain * accNavRaw;
end

accNav = accNavRaw - s.accBias;
accNav(3) = 0;

if dt > 0
    velPred = s.vel + accNav * dt;
    if zuptActive
        s.vel = [0 0 0];
    else
        s.vel = velPred;
        vNorm = norm(s.vel);
        if vNorm > cfg.maxFootSpeed
            s.vel = s.vel / vNorm * cfg.maxFootSpeed;
        end
        s.pos = s.pos + s.vel * dt;
    end

    s.vel(3) = 0;
    s.pos(3) = 0;
end

s.lastLoadIndex = loadIndex;
s.lastCOPyNorm = region.copYNorm;

g = struct();
g.total = region.total;
g.heel = region.heel;
g.mid = region.mid;
g.fore = region.fore;
g.toe = region.toe;
g.medial = region.medial;
g.lateral = region.lateral;
g.R_heel = R_heel;
g.R_mid = R_mid;
g.R_fore = R_fore;
g.R_toe = R_toe;
g.R_foreToe = foreToeRatio;
g.R_medial = R_medial;
g.R_lateral = R_lateral;
g.COPxNorm = region.copXNorm;
g.COPyNorm = region.copYNorm;
g.loadIndex = loadIndex;
g.contact = s.contact;
g.heelStrike = heelStrike;
g.heelOff = heelOff;
g.pushOff = pushOff;
g.toeOff = toeOff;
g.zuptActive = zuptActive;
g.stepCount = s.stepCount;
g.dLoad = dLoad;
g.dCOPy = dCOPy;
g.vel = s.vel;
g.pos = s.pos;

end

function logger = openLowLatencyCsvLogger(cfg)

logger = struct();
logger.fileName = cfg.log.fileName;
logger.fid = fopen(logger.fileName, 'w');
if logger.fid < 0
    error('Cannot open CSV file: %s', logger.fileName);
end

logger.runtimeTic = tic;
logger.pending = cell(cfg.log.flushEveryRows, 1);
logger.pendingCount = 0;
logger.rowsWritten = 0;
logger.lastFlushTime = tic;

header = ['t,aligned_time,gateway_t,gateway_time,arrival_t,arrival_time,' ...
    'alignment_method,alignment_ready,alignment_offset_ms,foot,imu_age_ms,processing_latency_ms,' ...
    'total,heel,mid,fore,toe,medial,lateral,' ...
    'R_heel,R_mid,R_fore,R_toe,R_foreToe,R_medial,R_lateral,COPxNorm,COPyNorm,' ...
    'loadIndex,contact,heelStrike,heelOff,pushOff,toeOff,zupt,footStepCount,totalStepCount,' ...
    'velX,velY,posX,posY'];

if cfg.log.includePressureValues
    for k = 1:48
        header = sprintf('%s,p%02d', header, k);
    end
end

fprintf(logger.fid, '%s\n', header);

end

function decodedLoggers = openDecodedSensorLoggers(cfg)

decodedLoggers = struct();
decodedLoggers.imu = openOneDecodedSensorLogger(cfg.decodedLog.imuFileName, cfg.decodedLog.flushEveryRows, getImuDecodedHeader());
decodedLoggers.pressure = openOneDecodedSensorLogger(cfg.decodedLog.pressureFileName, cfg.decodedLog.flushEveryRows, getPressureDecodedHeader());

end

function logger = openOneDecodedSensorLogger(fileName, flushEveryRows, header)

logger = struct();
logger.fileName = fileName;
logger.fid = fopen(logger.fileName, 'w');
if logger.fid < 0
    error('Cannot open decoded sensor CSV file: %s', logger.fileName);
end

logger.pending = cell(flushEveryRows, 1);
logger.pendingCount = 0;
logger.rowsWritten = 0;
logger.lastFlushTime = tic;
fprintf(logger.fid, '%s\n', header);

end

function header = getImuDecodedHeader()

header = ['t,aligned_time,gateway_t,gateway_time,arrival_t,arrival_time,' ...
    'alignment_method,alignment_ready,alignment_offset_ms,foot,phase,processing_latency_ms,' ...
    'stream_accepted,' ...
    'tag,main_status,status_ext,data_bitmap,' ...
    'accX_ms2,accY_ms2,accZ_ms2,accX_g,accY_g,accZ_g,' ...
    'q_w,q_x,q_y,q_z,crc'];

end

function header = getPressureDecodedHeader()

header = ['t,aligned_time,gateway_t,gateway_time,arrival_t,arrival_time,' ...
    'alignment_method,alignment_ready,alignment_offset_ms,foot,phase,processing_latency_ms,' ...
    'stream_accepted,' ...
    'total,active_sensor_count,max_pressure,' ...
    'heel,mid,fore,toe,medial,lateral,COPxNorm,COPyNorm'];
for k = 1:48
    header = sprintf('%s,p%02d', header, k);
end

end

function rawLogger = openOptionalRawLogger(cfg)

rawLogger = struct();
rawLogger.enabled = isfield(cfg, 'rawLog') && isfield(cfg.rawLog, 'enable') && cfg.rawLog.enable;
rawLogger.fid = -1;
rawLogger.pending = {};
rawLogger.pendingCount = 0;
rawLogger.rowsWritten = 0;
rawLogger.lastFlushTime = tic;

if ~rawLogger.enabled
    return;
end

rawLogger.fileName = cfg.rawLog.fileName;
rawLogger.pending = cell(cfg.rawLog.flushEveryRows, 1);
rawLogger.fid = fopen(rawLogger.fileName, 'w');
if rawLogger.fid < 0
    error('Cannot open raw CSV file: %s', rawLogger.fileName);
end

fprintf(rawLogger.fid, 'arrival_t,arrival_time,phase,topic,payload\n');

end

function stepLogger = openOptionalStepMetricsLogger(cfg)

stepLogger = struct();
stepLogger.enabled = isfield(cfg, 'trajectory') && ...
    getLogicalField(cfg.trajectory, 'stepMetricsLogEnable', false);
stepLogger.fid = -1;
stepLogger.pending = {};
stepLogger.pendingCount = 0;
stepLogger.rowsWritten = 0;
stepLogger.lastFlushTime = tic;
stepLogger.lastLeftStepCount = 0;
stepLogger.lastRightStepCount = 0;

if ~stepLogger.enabled
    return;
end

stepLogger.fileName = cfg.trajectory.stepMetricsLogFileName;
stepLogger.pending = cell(cfg.trajectory.stepMetricsLogFlushEveryRows, 1);
stepLogger.fid = fopen(stepLogger.fileName, 'w');
if stepLogger.fid < 0
    error('Cannot open step metrics CSV file: %s', stepLogger.fileName);
end

fprintf(stepLogger.fid, ['t,foot,foot_step_count,lift_time,land_time,stride_duration_s,step_length_m,raw_step_length_m,' ...
    'zupt_correction_x,zupt_correction_y,zupt_correction_z,pre_zupt_vel_x,pre_zupt_vel_y,pre_zupt_vel_z,' ...
    'step_frequency_spm,step_speed_mps,' ...
    'last_stance_duration_s,last_swing_duration_s,landing_pos_x,landing_pos_y,landing_pos_z,' ...
    'raw_z_min,raw_z_max,corrected_z_min,corrected_z_max,' ...
    'vertical_swing_bias,vertical_bias_residual,' ...
    'suspicious_step,long_swing_warning,missed_landing_suspected\n']);

end

function trajLogger = openOptionalTrajectoryStateLogger(cfg)

trajLogger = struct();
trajLogger.enabled = isfield(cfg, 'trajectory') && ...
    getLogicalField(cfg.trajectory, 'stateLogEnable', false);
trajLogger.fid = -1;
trajLogger.pending = {};
trajLogger.pendingCount = 0;
trajLogger.rowsWritten = 0;
trajLogger.lastFlushTime = tic;

if ~trajLogger.enabled
    return;
end

trajLogger.fileName = cfg.trajectory.stateLogFileName;
trajLogger.pending = cell(cfg.trajectory.stateLogFlushEveryRows, 1);
trajLogger.fid = fopen(trajLogger.fileName, 'w');
if trajLogger.fid < 0
    error('Cannot open trajectory state CSV file: %s', trajLogger.fileName);
end

fprintf(trajLogger.fid, ['t,updated_foot,' ...
    'left_pos_x,left_pos_y,left_pos_z,left_vel_x,left_vel_y,left_vel_z,left_q_w,left_q_x,left_q_y,left_q_z,left_zupt,left_contact,left_step_count,left_raw_pos_x,left_raw_pos_y,left_raw_pos_z,left_vertical_swing_bias,left_vertical_bias_residual,' ...
    'right_pos_x,right_pos_y,right_pos_z,right_vel_x,right_vel_y,right_vel_z,right_q_w,right_q_x,right_q_y,right_q_z,right_zupt,right_contact,right_step_count,right_raw_pos_x,right_raw_pos_y,right_raw_pos_z,right_vertical_swing_bias,right_vertical_bias_residual\n']);

end

function trajLogger = appendTrajectoryStateFromEstimator(trajLogger, estimator, msg, cfg)

if ~isfield(trajLogger, 'enabled') || ~trajLogger.enabled || isempty(estimator)
    return;
end

row = makeTrajectoryStateCsvRow(estimator, msg);
trajLogger.pendingCount = trajLogger.pendingCount + 1;
trajLogger.pending{trajLogger.pendingCount} = row;

if trajLogger.pendingCount >= cfg.trajectory.stateLogFlushEveryRows
    trajLogger = flushOptionalTrajectoryStateLogger(trajLogger);
end

end

function row = makeTrajectoryStateCsvRow(estimator, msg)

left = getFieldOrDefault(estimator, 'left', struct());
right = getFieldOrDefault(estimator, 'right', struct());

row = sprintf(['%.6f,%s,' ...
    '%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.9g,%.9g,%.9g,%.9g,%d,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,' ...
    '%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.9g,%.9g,%.9g,%.9g,%d,%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f'], ...
    getScalarOrDefault(estimator, 'lastUpdateT', getScalarOrDefault(msg, 'recv_time_sec', NaN)), ...
    char(getFieldOrDefault(msg, 'foot', "")), ...
    serializeFootTrajectoryState(left), ...
    serializeFootTrajectoryState(right));

end

function values = serializeFootTrajectoryState(foot)

rawPos = getVectorOrDefault(foot, 'pos', [NaN NaN NaN]);
pos = getVectorOrDefault(foot, 'displayPos', rawPos);
vel = getVectorOrDefault(foot, 'vel', [NaN NaN NaN]);
q = getVectorOrDefault(foot, 'lastQuatWxyz', [NaN NaN NaN NaN]);

values = [ ...
    pos(1), pos(2), pos(3), ...
    vel(1), vel(2), vel(3), ...
    q(1), q(2), q(3), q(4), ...
    logicalTo01(getScalarOrDefault(foot, 'zuptActive', false)), ...
    logicalTo01(getScalarOrDefault(foot, 'contact', false)), ...
    getScalarOrDefault(foot, 'stepCount', 0), ...
    rawPos(1), rawPos(2), rawPos(3), ...
    getScalarOrDefault(foot, 'swingVerticalBias', NaN), ...
    getScalarOrDefault(foot, 'lastVerticalSwingBiasResidual', NaN)];

end

function stepLogger = appendStepMetricsFromEstimator(stepLogger, estimator, cfg)

if ~isfield(stepLogger, 'enabled') || ~stepLogger.enabled || isempty(estimator)
    return;
end

stepLogger = appendOneFootStepMetric(stepLogger, estimator, cfg, 'left');
stepLogger = appendOneFootStepMetric(stepLogger, estimator, cfg, 'right');

end

function stepLogger = appendOneFootStepMetric(stepLogger, estimator, cfg, side)

if ~isfield(estimator, side)
    return;
end

foot = estimator.(side);
stepCount = getScalarOrDefault(foot, 'stepCount', 0);
if strcmp(side, 'left')
    lastField = 'lastLeftStepCount';
else
    lastField = 'lastRightStepCount';
end

if stepCount <= stepLogger.(lastField)
    return;
end

row = makeStepMetricCsvRow(foot, side, stepCount);
stepLogger.pendingCount = stepLogger.pendingCount + 1;
stepLogger.pending{stepLogger.pendingCount} = row;

if stepLogger.pendingCount >= cfg.trajectory.stepMetricsLogFlushEveryRows
    stepLogger = flushOptionalStepMetricsLogger(stepLogger);
end

stepLogger.(lastField) = stepCount;

end

function row = makeStepMetricCsvRow(foot, side, stepCount)

landingPos = getVectorOrDefault(foot, 'lastLandingPos', [NaN NaN NaN]);
landingCorrection = getVectorOrDefault(foot, 'lastLandingCorrection', [NaN NaN NaN]);
preZuptVelocity = getVectorOrDefault(foot, 'preZuptVelocity', [NaN NaN NaN]);
[rawZMin, rawZMax] = getSwingVerticalRange(foot, 'lastRawSwingPos');
[correctedZMin, correctedZMax] = getSwingVerticalRange(foot, 'lastCorrectedSwingPos');

landTime = getScalarOrDefault(foot, 'lastLandingT', NaN);
liftTime = getScalarOrDefault(foot, 'swingStartT', NaN);
strideDuration = getDurationForLog(liftTime, landTime);

row = sprintf(['%.6f,%s,%d,%.6f,%.6f,%.6f,%.6f,%.6f,' ...
    '%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,' ...
    '%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,' ...
    '%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d'], ...
    getScalarOrDefault(foot, 'lastLandingT', NaN), ...
    side, ...
    stepCount, ...
    liftTime, ...
    landTime, ...
    strideDuration, ...
    getScalarOrDefault(foot, 'stepLength', NaN), ...
    getScalarOrDefault(foot, 'rawStepLength', NaN), ...
    landingCorrection(1), landingCorrection(2), landingCorrection(3), ...
    preZuptVelocity(1), preZuptVelocity(2), preZuptVelocity(3), ...
    getScalarOrDefault(foot, 'stepCadence', NaN), ...
    getScalarOrDefault(foot, 'stepSpeed', NaN), ...
    getScalarOrDefault(foot, 'lastStanceDuration', NaN), ...
    getScalarOrDefault(foot, 'lastSwingDuration', NaN), ...
    landingPos(1), landingPos(2), landingPos(3), ...
    rawZMin, rawZMax, correctedZMin, correctedZMax, ...
    getScalarOrDefault(foot, 'swingVerticalBias', NaN), ...
    getScalarOrDefault(foot, 'lastVerticalSwingBiasResidual', NaN), ...
    logicalTo01(getScalarOrDefault(foot, 'suspiciousStep', false)), ...
    logicalTo01(getScalarOrDefault(foot, 'longSwingWarning', false)), ...
    logicalTo01(getScalarOrDefault(foot, 'missedLandingSuspected', false)));

end

function [zMin, zMax] = getSwingVerticalRange(foot, fieldName)

zMin = NaN;
zMax = NaN;
if ~isstruct(foot) || ~isfield(foot, fieldName)
    return;
end

positions = double(foot.(fieldName));
if size(positions, 2) < 3 || isempty(positions)
    return;
end

z = positions(:, 3);
z = z(isfinite(z));
if ~isempty(z)
    zMin = min(z);
    zMax = max(z);
end

end

function d = getDurationForLog(t0, t1)

if isfinite(t0) && isfinite(t1) && t1 >= t0
    d = t1 - t0;
else
    d = NaN;
end

end

function rawLogger = appendRawBatch(rawLogger, batch, cfg, phase)

if ~isfield(rawLogger, 'enabled') || ~rawLogger.enabled || isempty(batch)
    return;
end

for i = 1:numel(batch)
    rawMsg = batch{i};
    [arrivalT, arrivalTimeStr] = getMqttArrivalTimestamp(rawMsg);
    row = sprintf('%.6f,%s,%s,%s,%s', ...
        arrivalT, csvEscapeLocal(arrivalTimeStr), ...
        csvEscapeLocal(phase), ...
        csvEscapeLocal(string(rawMsg.Topic)), ...
        csvEscapeLocal(rawPayloadToText(rawMsg.Data)));

    rawLogger.pendingCount = rawLogger.pendingCount + 1;
    rawLogger.pending{rawLogger.pendingCount} = row;

    if rawLogger.pendingCount >= cfg.rawLog.flushEveryRows
        rawLogger = flushOptionalRawLogger(rawLogger);
    end
end

end

function decodedLoggers = appendDecodedSensorMessage(decodedLoggers, msg, rawMsg, cfg, phase, streamAccepted)

latencyMs = getProcessingLatencyMs(rawMsg);
if strcmp(msg.sensor_type, 'imu')
    row = sprintf('%s%s,%s,%.3f,%d,%s', ...
        makeMessageTimeCsvPrefix(msg), msg.foot, ...
        csvEscapeLocal(phase), latencyMs, logicalTo01(streamAccepted), ...
        serializeImuDecodedFields(msg.data));
    decodedLoggers.imu = appendDecodedSensorRow(decodedLoggers.imu, row, cfg);
elseif strcmp(msg.sensor_type, 'pressure')
    row = formatDecodedPressureCsvRow(msg, phase, latencyMs, streamAccepted, ...
        cfg.gait, cfg.log.pressureActiveThreshold);
    decodedLoggers.pressure = appendDecodedSensorRow(decodedLoggers.pressure, row, cfg);
end

end

function latencyMs = getProcessingLatencyMs(rawMsg)

if isstruct(rawMsg) && isfield(rawMsg, 'RuntimeTic') && isfield(rawMsg, 'ArrivalT') && ...
        ~isempty(rawMsg.RuntimeTic) && ~isempty(rawMsg.ArrivalT)
    latencyMs = max(0, (toc(rawMsg.RuntimeTic) - double(rawMsg.ArrivalT)) * 1000);
else
    latencyMs = NaN;
end

end

function logger = appendDecodedSensorRow(logger, row, cfg)

logger.pendingCount = logger.pendingCount + 1;
logger.pending{logger.pendingCount} = row;

if logger.pendingCount >= cfg.decodedLog.flushEveryRows
    logger = flushOneDecodedSensorLogger(logger);
end

end

function decodedLoggers = maybeFlushDecodedSensorLoggers(decodedLoggers, cfg)

if toc(decodedLoggers.imu.lastFlushTime) >= cfg.decodedLog.flushEverySec
    decodedLoggers.imu = flushOneDecodedSensorLogger(decodedLoggers.imu);
end
if toc(decodedLoggers.pressure.lastFlushTime) >= cfg.decodedLog.flushEverySec
    decodedLoggers.pressure = flushOneDecodedSensorLogger(decodedLoggers.pressure);
end

end

function logger = flushOneDecodedSensorLogger(logger)

if logger.pendingCount <= 0
    logger.lastFlushTime = tic;
    return;
end

for i = 1:logger.pendingCount
    fprintf(logger.fid, '%s\n', logger.pending{i});
end

logger.rowsWritten = logger.rowsWritten + logger.pendingCount;
logger.pending(1:logger.pendingCount) = {[]};
logger.pendingCount = 0;
logger.lastFlushTime = tic;

end

function rawLogger = maybeFlushOptionalRawLogger(rawLogger, cfg)

if ~isfield(rawLogger, 'enabled') || ~rawLogger.enabled
    return;
end

if toc(rawLogger.lastFlushTime) >= cfg.rawLog.flushEverySec
    rawLogger = flushOptionalRawLogger(rawLogger);
end

end

function stepLogger = maybeFlushOptionalStepMetricsLogger(stepLogger, cfg)

if ~isfield(stepLogger, 'enabled') || ~stepLogger.enabled
    return;
end

if toc(stepLogger.lastFlushTime) >= cfg.trajectory.stepMetricsLogFlushEverySec
    stepLogger = flushOptionalStepMetricsLogger(stepLogger);
end

end

function trajLogger = maybeFlushOptionalTrajectoryStateLogger(trajLogger, cfg)

if ~isfield(trajLogger, 'enabled') || ~trajLogger.enabled
    return;
end

if toc(trajLogger.lastFlushTime) >= cfg.trajectory.stateLogFlushEverySec
    trajLogger = flushOptionalTrajectoryStateLogger(trajLogger);
end

end

function rawLogger = flushOptionalRawLogger(rawLogger)

if ~isfield(rawLogger, 'enabled') || ~rawLogger.enabled || rawLogger.pendingCount <= 0
    rawLogger.lastFlushTime = tic;
    return;
end

for i = 1:rawLogger.pendingCount
    fprintf(rawLogger.fid, '%s\n', rawLogger.pending{i});
end

rawLogger.rowsWritten = rawLogger.rowsWritten + rawLogger.pendingCount;
rawLogger.pending(1:rawLogger.pendingCount) = {[]};
rawLogger.pendingCount = 0;
rawLogger.lastFlushTime = tic;

end

function stepLogger = flushOptionalStepMetricsLogger(stepLogger)

if ~isfield(stepLogger, 'enabled') || ~stepLogger.enabled || stepLogger.pendingCount <= 0
    stepLogger.lastFlushTime = tic;
    return;
end

for i = 1:stepLogger.pendingCount
    fprintf(stepLogger.fid, '%s\n', stepLogger.pending{i});
end

stepLogger.rowsWritten = stepLogger.rowsWritten + stepLogger.pendingCount;
stepLogger.pending(1:stepLogger.pendingCount) = {[]};
stepLogger.pendingCount = 0;
stepLogger.lastFlushTime = tic;

end

function trajLogger = flushOptionalTrajectoryStateLogger(trajLogger)

if ~isfield(trajLogger, 'enabled') || ~trajLogger.enabled || trajLogger.pendingCount <= 0
    trajLogger.lastFlushTime = tic;
    return;
end

for i = 1:trajLogger.pendingCount
    fprintf(trajLogger.fid, '%s\n', trajLogger.pending{i});
end

trajLogger.rowsWritten = trajLogger.rowsWritten + trajLogger.pendingCount;
trajLogger.pending(1:trajLogger.pendingCount) = {[]};
trajLogger.pendingCount = 0;
trajLogger.lastFlushTime = tic;

end

function text = rawPayloadToText(payload)

if isa(payload, 'uint8')
    text = string(char(payload(:).'));
elseif isstring(payload)
    text = payload;
elseif ischar(payload)
    text = string(payload);
else
    text = string(evalc('disp(payload)'));
end

text = erase(text, char(0));
text = regexprep(text, '[\r\n]+$', '');

end

function out = csvEscapeLocal(value)

out = char(value);
out = strrep(out, '"', '""');
if contains(out, ',') || contains(out, '"') || contains(out, newline) || contains(out, sprintf('\r'))
    out = ['"' out '"'];
end

end

function plotState = initOptionalPlotState()

plotState = struct();
plotState.pressure = [];
plotState.imu = [];
plotState.trajectory = [];
plotState.stepMetrics = [];
plotState.lastPressurePlotTime = tic;
plotState.lastImuPlotTime = tic;
plotState.lastTrajectoryPlotTime = tic;
plotState.runtimeTic = tic;

end

function plotState = preinitializeAnalysisFigures(plotState, cfg)

% Figure construction and first rendering can take several seconds in the
% desktop graphics process. Pay that cost before subscribing to MQTT so no
% sensor frames accumulate while graphics objects are being created.
closeExistingAnalysisFigure('IMU + Pressure ZUPT Trajectory');
closeExistingAnalysisFigure('Step Metrics');

if cfg.trajectory.figureEnable
    plotState.trajectory = initTrajectoryFigure(cfg.trajectory);
end
if cfg.trajectory.stepMetricsFigureEnable
    plotState.stepMetrics = initStepMetricsFigure( ...
        struct('maxPoints', cfg.trajectory.stepMetricsMaxPoints));
end
drawnow;
plotState.lastTrajectoryPlotTime = tic;

end

function closeExistingAnalysisFigure(figureName)

figures = findall(0, 'Type', 'figure', 'Name', figureName);
for k = 1:numel(figures)
    if isvalid(figures(k))
        close(figures(k));
    end
end

end

function plotState = updateOptionalPlots(plotState, state, trajectoryEstimator, analysisEnabled, cfg)

if ~isfield(cfg, 'plot')
    return;
end

if isfield(cfg.plot, 'fullPressureEnable') && cfg.plot.fullPressureEnable
    if toc(plotState.lastPressurePlotTime) >= cfg.plot.fullPressureRefreshEverySec
        if any(isfinite(state.left.latestPressure)) && any(isfinite(state.right.latestPressure))
            sample = makePlotSample(state);
            if getStringField(cfg.plot, 'pressureMode', "fast") == "full"
                plotState.pressure = updateRealtimePressureInsoleFigure(plotState.pressure, sample, cfg.gait);
                plotState.lastPressurePlotTime = tic;
            else
                % Fast pressure is drawn inside the low-latency monitor.
            end
        end
    end
end

if isfield(cfg.plot, 'imuEnable') && cfg.plot.imuEnable
    if toc(plotState.lastImuPlotTime) >= cfg.plot.imuRefreshEverySec
        if ~isempty(state.left.latestImu) && ~isempty(state.right.latestImu)
            sample = makePlotSample(state);
            if getStringField(cfg.plot, 'imuMode', "fast") == "full"
                plotState.imu = updateRealtimeImuFigure(plotState.imu, sample);
                plotState.lastImuPlotTime = tic;
            else
                % Fast acceleration is drawn inside the low-latency monitor.
            end
        end
    end
end

if analysisEnabled && isfield(cfg, 'trajectory') && ...
        isfield(cfg.trajectory, 'figureEnable') && cfg.trajectory.figureEnable
    if toc(plotState.lastTrajectoryPlotTime) >= cfg.trajectory.figureRefreshEverySec
        plotState.trajectory = updateTrajectoryFigure(plotState.trajectory, trajectoryEstimator, cfg.trajectory);
        plotState.lastTrajectoryPlotTime = tic;
    end
end

if analysisEnabled && isfield(cfg, 'trajectory') && ...
        isfield(cfg.trajectory, 'stepMetricsFigureEnable') && cfg.trajectory.stepMetricsFigureEnable
    plotState.stepMetrics = updateStepMetricsFigure(plotState.stepMetrics, trajectoryEstimator, ...
        struct('maxPoints', cfg.trajectory.stepMetricsMaxPoints));
end

end

function sample = makePlotSample(state)

sample = struct();
sample.t = getLatestSensorTimestamp(state);

sample.left.pressure.data.values = state.left.latestPressure;
sample.right.pressure.data.values = state.right.latestPressure;

if ~isempty(state.left.latestImu)
    sample.left.imu = state.left.latestImu;
else
    sample.left.imu.data = struct();
end

if ~isempty(state.right.latestImu)
    sample.right.imu = state.right.latestImu;
else
    sample.right.imu.data = struct();
end

end

function t = getLatestSensorTimestamp(state)

times = [ ...
    getMessageTimestamp(state.left.latestImu), ...
    getMessageTimestamp(state.right.latestImu), ...
    getScalarOrDefault(state.left, 'latestPressureT', NaN), ...
    getScalarOrDefault(state.right, 'latestPressureT', NaN)];
times = times(isfinite(times));

if isempty(times)
    t = NaN;
else
    t = max(times);
end

end

function t = getLatestImuSensorTimestamp(state)

times = [getMessageTimestamp(state.left.latestImu), getMessageTimestamp(state.right.latestImu)];
times = times(isfinite(times));

if isempty(times)
    t = NaN;
else
    t = max(times);
end

end

function t = getMessageTimestamp(msg)

t = NaN;
if isstruct(msg) && isfield(msg, 'recv_time_sec') && ~isempty(msg.recv_time_sec)
    t = double(msg.recv_time_sec(1));
end

end

function sample = makeTrajectorySampleForMessage(state, msg)

sample = struct();
footName = char(msg.foot);
sample.t = msg.recv_time_sec;

if ~isfield(state, footName)
    return;
end

foot = state.(footName);
sample.(footName).t = msg.recv_time_sec;

if strcmp(msg.sensor_type, 'imu')
    sample.(footName).imu = msg;
elseif strcmp(msg.sensor_type, 'pressure')
    pressureMsg = msg;
    pressureValues = correctPressureValues( ...
        msg.data.values, getFieldOrDefault(foot, 'calib', struct()));
    pressureMsg.data.values = pressureValues;
    pressureMsg.data.sum = sum(pressureValues);
    sample.(footName).pressure = pressureMsg;
end

if isfield(foot, 'calibrated') && foot.calibrated && isfield(foot, 'calib')
    sample.(footName).calib = foot.calib;
end

end

function pressurePlot = updateFastPressureFigure(pressurePlot, state)

if isempty(pressurePlot) || ~isfield(pressurePlot, 'fig') || ~isvalid(pressurePlot.fig)
    pressurePlot = initFastPressureFigure();
end

leftM = pressureToDisplayMatrix(state.left.latestPressure, 'left');
rightM = pressureToDisplayMatrix(state.right.latestPressure, 'right');

set(pressurePlot.leftImage, 'CData', leftM);
set(pressurePlot.rightImage, 'CData', rightM);
set([pressurePlot.leftAx pressurePlot.rightAx], 'CLim', [0 1300]);

end

function pressurePlot = initFastPressureFigure()

pressurePlot = struct();
pressurePlot.fig = figure( ...
    'Name', 'Fast Pressure Heatmap', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'Position', [460 80 520 420]);

pressurePlot.leftAx = subplot(1, 2, 1, 'Parent', pressurePlot.fig);
pressurePlot.leftImage = imagesc(pressurePlot.leftAx, nan(12, 4));
title(pressurePlot.leftAx, 'Left Pressure');
formatPressureAxes(pressurePlot.leftAx, {'L', '', '', 'M'}, 'L -> M');

pressurePlot.rightAx = subplot(1, 2, 2, 'Parent', pressurePlot.fig);
pressurePlot.rightImage = imagesc(pressurePlot.rightAx, nan(12, 4));
title(pressurePlot.rightAx, 'Right Pressure');
formatPressureAxes(pressurePlot.rightAx, {'M', '', '', 'L'}, 'M -> L');

colormap(pressurePlot.fig, hot(256));
pressurePlot.pressureMax = 1;

end

function imuPlot = updateFastImuFigure(imuPlot, sample, plotCfg)

if isempty(imuPlot) || ~isfield(imuPlot, 'fig') || ~isvalid(imuPlot.fig)
    imuPlot = initFastImuFigure();
end

t = double(sample.t);
leftImu = getNestedOrDefault(sample, {'left','imu','data'}, struct());
rightImu = getNestedOrDefault(sample, {'right','imu','data'}, struct());

imuPlot.t(end + 1) = t;
imuPlot.leftAcc(end + 1, :) = getVec3OrDefault(leftImu, 'acc_g');
imuPlot.rightAcc(end + 1, :) = getVec3OrDefault(rightImu, 'acc_g');
imuPlot.leftGyro(end + 1, :) = getVec3OrDefault(leftImu, 'gyr_dps');
imuPlot.rightGyro(end + 1, :) = getVec3OrDefault(rightImu, 'gyr_dps');

maxPoints = max(20, round(getNumericField(plotCfg, 'fastImuMaxPoints', 250)));
if numel(imuPlot.t) > maxPoints
    idx = (numel(imuPlot.t) - maxPoints + 1):numel(imuPlot.t);
    imuPlot.t = imuPlot.t(idx);
    imuPlot.leftAcc = imuPlot.leftAcc(idx, :);
    imuPlot.rightAcc = imuPlot.rightAcc(idx, :);
    imuPlot.leftGyro = imuPlot.leftGyro(idx, :);
    imuPlot.rightGyro = imuPlot.rightGyro(idx, :);
end

tt = imuPlot.t - imuPlot.t(1);
leftAccNorm = vecnorm(imuPlot.leftAcc, 2, 2);
rightAccNorm = vecnorm(imuPlot.rightAcc, 2, 2);
leftGyroNorm = vecnorm(imuPlot.leftGyro, 2, 2);
rightGyroNorm = vecnorm(imuPlot.rightGyro, 2, 2);

set(imuPlot.leftAccLine, 'XData', tt, 'YData', leftAccNorm);
set(imuPlot.rightAccLine, 'XData', tt, 'YData', rightAccNorm);
set(imuPlot.leftGyroLine, 'XData', tt, 'YData', leftGyroNorm);
set(imuPlot.rightGyroLine, 'XData', tt, 'YData', rightGyroNorm);
ylim(imuPlot.accAx, getNumericField(plotCfg, 'accelYLim', [0 3]));

if ~isempty(tt)
    xEnd = max(5, tt(end));
    xStart = max(0, xEnd - 5);
    set([imuPlot.accAx imuPlot.gyroAx], 'XLim', [xStart xEnd]);
end

end

function imuPlot = initFastImuFigure()

imuPlot = struct();
imuPlot.fig = figure( ...
    'Name', 'Fast IMU Monitor', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'Position', [1000 80 620 420]);

imuPlot.accAx = subplot(2, 1, 1, 'Parent', imuPlot.fig);
hold(imuPlot.accAx, 'on');
grid(imuPlot.accAx, 'on');
title(imuPlot.accAx, 'Acceleration Norm');
ylabel(imuPlot.accAx, 'g');
imuPlot.leftAccLine = plot(imuPlot.accAx, nan, nan, 'r-', 'LineWidth', 1.0);
imuPlot.rightAccLine = plot(imuPlot.accAx, nan, nan, 'b-', 'LineWidth', 1.0);
legend(imuPlot.accAx, {'L acc', 'R acc'}, 'Location', 'northeast');

imuPlot.gyroAx = subplot(2, 1, 2, 'Parent', imuPlot.fig);
hold(imuPlot.gyroAx, 'on');
grid(imuPlot.gyroAx, 'on');
title(imuPlot.gyroAx, 'Gyro Norm');
ylabel(imuPlot.gyroAx, 'deg/s');
xlabel(imuPlot.gyroAx, 'Time / s');
imuPlot.leftGyroLine = plot(imuPlot.gyroAx, nan, nan, 'r-', 'LineWidth', 1.0);
imuPlot.rightGyroLine = plot(imuPlot.gyroAx, nan, nan, 'b-', 'LineWidth', 1.0);
legend(imuPlot.gyroAx, {'L gyro', 'R gyro'}, 'Location', 'northeast');

imuPlot.t = [];
imuPlot.leftAcc = zeros(0, 3);
imuPlot.rightAcc = zeros(0, 3);
imuPlot.leftGyro = zeros(0, 3);
imuPlot.rightGyro = zeros(0, 3);

end

function value = getStringField(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = string(s.(fieldName));
else
    value = string(defaultValue);
end

end

function value = getLogicalField(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = logical(s.(fieldName));
else
    value = defaultValue;
end

end

function value = getNumericField(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName)) && isnumeric(s.(fieldName))
    value = double(s.(fieldName));
else
    value = defaultValue;
end

end

function v = getNestedOrDefault(s, path, defaultValue)

v = s;
for i = 1:numel(path)
    name = path{i};
    if isstruct(v) && isfield(v, name) && ~isempty(v.(name))
        v = v.(name);
    else
        v = defaultValue;
        return;
    end
end

end

function v = getVec3OrDefault(s, fieldName)

if isstruct(s) && isfield(s, fieldName) && numel(s.(fieldName)) >= 3
    v = double(s.(fieldName)(1:3));
    v = v(:).';
else
    v = [NaN NaN NaN];
end

end

function monitor = initLatencyMonitor(cfg)

monitor = struct();
monitor.enabled = isfield(cfg, 'monitor') && isfield(cfg.monitor, 'enable') && cfg.monitor.enable;
monitor.lastUpdateTime = tic;

if ~monitor.enabled
    return;
end

monitor.fig = figure( ...
    'Name', 'Gait Calibration and Recording Control', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'MenuBar', 'none', ...
    'ToolBar', 'none', ...
    'Position', [80 80 1080 620], ...
    'CloseRequestFcn', @(src, ~) requestGaitSessionShutdown( ...
        src, cfg.control.appdataKey));

monitor.ax = axes('Parent', monitor.fig, ...
    'Position', [0 0 1 1], ...
    'Visible', 'off');

monitor.titleText = text(monitor.ax, 0.04, 0.94, 'Gait Capture Workflow', ...
    'Units', 'normalized', ...
    'FontSize', 15, ...
    'FontWeight', 'bold', ...
    'Color', [0.05 0.05 0.05]);

monitor.tapAlignmentCheckbox = uicontrol(monitor.fig, ...
    'Style', 'checkbox', ...
    'Tag', 'gaitTapAlignmentCheckbox', ...
    'Units', 'normalized', ...
    'Position', [0.04 0.35 0.12 0.055], ...
    'String', '启用硬板敲击', ...
    'Value', logical(cfg.timeAlignment.useTap), ...
    'BackgroundColor', 'w', ...
    'FontSize', 9.5);

monitor.leftGatewayLabel = uicontrol(monitor.fig, ...
    'Style', 'text', ...
    'Units', 'normalized', ...
    'Position', [0.39 0.925 0.09 0.035], ...
    'String', '左脚网关 ID', ...
    'BackgroundColor', 'w', ...
    'HorizontalAlignment', 'right', ...
    'FontSize', 9.5);
monitor.leftGatewayEdit = uicontrol(monitor.fig, ...
    'Style', 'edit', ...
    'Units', 'normalized', ...
    'Position', [0.49 0.925 0.125 0.042], ...
    'String', char(cfg.mqtt.gatewayIds.left), ...
    'BackgroundColor', 'w', ...
    'HorizontalAlignment', 'left', ...
    'FontName', 'Consolas', ...
    'FontSize', 9.5);
monitor.rightGatewayLabel = uicontrol(monitor.fig, ...
    'Style', 'text', ...
    'Units', 'normalized', ...
    'Position', [0.62 0.925 0.09 0.035], ...
    'String', '右脚网关 ID', ...
    'BackgroundColor', 'w', ...
    'HorizontalAlignment', 'right', ...
    'FontSize', 9.5);
monitor.rightGatewayEdit = uicontrol(monitor.fig, ...
    'Style', 'edit', ...
    'Units', 'normalized', ...
    'Position', [0.72 0.925 0.125 0.042], ...
    'String', char(cfg.mqtt.gatewayIds.right), ...
    'BackgroundColor', 'w', ...
    'HorizontalAlignment', 'left', ...
    'FontName', 'Consolas', ...
    'FontSize', 9.5);
monitor.gatewayConnectButton = uicontrol(monitor.fig, ...
    'Style', 'pushbutton', ...
    'Tag', 'gaitGatewayConnectButton', ...
    'Units', 'normalized', ...
    'Position', [0.86 0.922 0.11 0.048], ...
    'String', '应用并连接', ...
    'FontSize', 9.5, ...
    'FontWeight', 'bold');
monitor.gatewayStatusText = uicontrol(monitor.fig, ...
    'Style', 'text', ...
    'Units', 'normalized', ...
    'Position', [0.40 0.882 0.56 0.030], ...
    'String', '请确认左右脚网关 ID', ...
    'BackgroundColor', 'w', ...
    'ForegroundColor', [0.15 0.28 0.55], ...
    'HorizontalAlignment', 'right', ...
    'FontSize', 8.5);
set(monitor.gatewayConnectButton, 'Callback', @(~, ~) ...
    submitGatewayConfiguration( ...
        monitor.fig, monitor.leftGatewayEdit, monitor.rightGatewayEdit, ...
        monitor.gatewayConnectButton, monitor.gatewayStatusText, ...
        monitor.tapAlignmentCheckbox, cfg));

monitor.phaseText = text(monitor.ax, 0.04, 0.84, 'Waiting for gateway connection', ...
    'Units', 'normalized', ...
    'FontSize', 12, ...
    'FontWeight', 'bold', ...
    'Color', [0.15 0.28 0.55]);

monitor.statusText = text(monitor.ax, 0.04, 0.75, 'Starting...', ...
    'Units', 'normalized', ...
    'FontSize', 10, ...
    'FontName', 'Consolas', ...
    'Color', [0.05 0.05 0.05], ...
    'VerticalAlignment', 'top');

monitor.calibrationText = text(monitor.ax, 0.04, 0.49, '', ...
    'Units', 'normalized', ...
    'FontSize', 9.5, ...
    'Color', [0.12 0.12 0.12], ...
    'VerticalAlignment', 'top');

buttonPosition = [0.165 0.35 0.165 0.055];
monitor.tapAlignmentButton = uicontrol(monitor.fig, ...
    'Style', 'pushbutton', ...
    'Tag', 'gaitTapAlignmentButton', ...
    'Units', 'normalized', ...
    'Position', buttonPosition, ...
    'String', '开始敲击时间对齐', ...
    'FontSize', 9.5, ...
    'Enable', 'off', ...
    'Callback', @(~, ~) queueGaitSessionCommand( ...
        cfg.control.appdataKey, 'start_time_alignment'));
buttonPosition = [0.04 0.28 0.29 0.055];
monitor.unloadedButton = uicontrol(monitor.fig, ...
    'Style', 'pushbutton', ...
    'Tag', 'gaitUnloadedCalibrationButton', ...
    'Units', 'normalized', ...
    'Position', buttonPosition, ...
    'String', '1. 不穿鞋校准', ...
    'FontSize', 10, ...
    'Enable', 'off', ...
    'Callback', @(~, ~) queueGaitSessionCommand( ...
        cfg.control.appdataKey, 'start_unloaded'));
buttonPosition(2) = 0.21;
monitor.wornButton = uicontrol(monitor.fig, ...
    'Style', 'pushbutton', ...
    'Tag', 'gaitWornPreparationButton', ...
    'Units', 'normalized', ...
    'Position', buttonPosition, ...
    'String', '2. 穿鞋站立准备', ...
    'FontSize', 10, ...
    'Enable', 'off', ...
    'Callback', @(~, ~) queueGaitSessionCommand( ...
        cfg.control.appdataKey, 'start_worn'));
buttonPosition(2) = 0.14;
monitor.startButton = uicontrol(monitor.fig, ...
    'Style', 'pushbutton', ...
    'Tag', 'gaitStartRecordingButton', ...
    'Units', 'normalized', ...
    'Position', buttonPosition, ...
    'String', '3. 正式开始分析和记录', ...
    'FontSize', 10, ...
    'FontWeight', 'bold', ...
    'Enable', 'off', ...
    'Callback', @(~, ~) queueGaitSessionCommand( ...
        cfg.control.appdataKey, 'start_recording'));
buttonPosition(2) = 0.07;
monitor.stopButton = uicontrol(monitor.fig, ...
    'Style', 'pushbutton', ...
    'Tag', 'gaitStopRecordingButton', ...
    'Units', 'normalized', ...
    'Position', buttonPosition, ...
    'String', '4. 结束分析和记录', ...
    'FontSize', 10, ...
    'Enable', 'off', ...
    'Callback', @(~, ~) queueGaitSessionCommand( ...
        cfg.control.appdataKey, 'stop_recording'));

monitor.leftAx = axes('Parent', monitor.fig, 'Position', [0.42 0.43 0.17 0.42]);
monitor.leftImage = imagesc(monitor.leftAx, nan(12, 4));
title(monitor.leftAx, 'Left Pressure');
formatPressureAxes(monitor.leftAx, {'L', '', '', 'M'}, 'L -> M');
set(monitor.leftAx, 'CLim', cfg.monitor.pressureCLim);

monitor.rightAx = axes('Parent', monitor.fig, 'Position', [0.63 0.43 0.17 0.42]);
monitor.rightImage = imagesc(monitor.rightAx, nan(12, 4));
title(monitor.rightAx, 'Right Pressure');
formatPressureAxes(monitor.rightAx, {'M', '', '', 'L'}, 'M -> L');
set(monitor.rightAx, 'CLim', cfg.monitor.pressureCLim);

monitor.accAx = axes('Parent', monitor.fig, 'Position', [0.40 0.10 0.56 0.23]);
hold(monitor.accAx, 'on');
grid(monitor.accAx, 'on');
title(monitor.accAx, 'Acceleration Norm');
xlabel(monitor.accAx, 'Time / s');
ylabel(monitor.accAx, 'g');
monitor.leftAccLine = plot(monitor.accAx, nan, nan, 'r-', 'LineWidth', 1.0);
monitor.rightAccLine = plot(monitor.accAx, nan, nan, 'b-', 'LineWidth', 1.0);
legend(monitor.accAx, {'Left', 'Right'}, 'Location', 'northeast');
ylim(monitor.accAx, cfg.monitor.accelYLim);
monitor.accT = [];
monitor.leftAccNorm = [];
monitor.rightAccNorm = [];
monitor.runtimeTic = tic;

colormap(monitor.fig, hot(256));
monitor.pressureMax = 1;

drawnow limitrate;

end

function [cfg, accepted] = waitForGatewayConfiguration(monitor, cfg)

accepted = false;
if ~isfield(monitor, 'enabled') || ~monitor.enabled
    accepted = true;
    return;
end
if ~isfield(monitor, 'fig') || isempty(monitor.fig) || ~isvalid(monitor.fig)
    return;
end

uiwait(monitor.fig);
if ~isvalid(monitor.fig) || ...
        ~isappdata(monitor.fig, 'GaitGatewayConfiguration')
    return;
end

cfg = getappdata(monitor.fig, 'GaitGatewayConfiguration');
rmappdata(monitor.fig, 'GaitGatewayConfiguration');
accepted = true;

try
    setpref(cfg.mqtt.gatewayPreferenceGroup, ...
        cfg.mqtt.leftGatewayPreference, char(cfg.mqtt.gatewayIds.left));
    setpref(cfg.mqtt.gatewayPreferenceGroup, ...
        cfg.mqtt.rightGatewayPreference, char(cfg.mqtt.gatewayIds.right));
catch ME
    warning('gait:GatewayPreferenceSaveFailed', ...
        'Could not save gateway ID preferences: %s', ME.message);
end

end

function submitGatewayConfiguration(fig, leftEdit, rightEdit, ...
        connectButton, statusText, tapAlignmentCheckbox, cfg)

if isempty(fig) || ~isvalid(fig)
    return;
end

try
    selectedCfg = configureGaitGatewayIds( ...
        cfg, get(leftEdit, 'String'), get(rightEdit, 'String'));
    selectedCfg.timeAlignment.useTap = ...
        logical(get(tapAlignmentCheckbox, 'Value'));
catch ME
    if strcmp(ME.identifier, 'gait:DuplicateGatewayId')
        message = '左右脚网关 ID 不能相同';
    else
        message = '网关 ID 必须是 12 位十六进制字符';
    end
    set(statusText, 'String', message, ...
        'ForegroundColor', [0.75 0.05 0.05]);
    return;
end

set(leftEdit, 'String', char(selectedCfg.mqtt.gatewayIds.left), ...
    'Enable', 'off');
set(rightEdit, 'String', char(selectedCfg.mqtt.gatewayIds.right), ...
    'Enable', 'off');
set(connectButton, 'Enable', 'off');
set(statusText, 'String', '正在连接 MQTT...', ...
    'ForegroundColor', [0.15 0.28 0.55]);
setappdata(fig, 'GaitGatewayConfiguration', selectedCfg);
drawnow;
uiresume(fig);

end

function monitor = showGatewayConnected(monitor, cfg, timeAlignment)

if ~isfield(monitor, 'enabled') || ~monitor.enabled || ...
        ~isfield(monitor, 'fig') || isempty(monitor.fig) || ~isvalid(monitor.fig)
    return;
end

set(monitor.leftGatewayEdit, ...
    'String', char(cfg.mqtt.gatewayIds.left), 'Enable', 'off');
set(monitor.rightGatewayEdit, ...
    'String', char(cfg.mqtt.gatewayIds.right), 'Enable', 'off');
set(monitor.gatewayConnectButton, ...
    'String', '已连接', 'Enable', 'off');
set(monitor.tapAlignmentCheckbox, 'Enable', 'off');
set(monitor.gatewayStatusText, ...
    'String', 'MQTT 已连接，网关设置已锁定', ...
    'ForegroundColor', [0.00 0.45 0.18]);
set(monitor.phaseText, ...
    'String', workflowPhaseDisplayName("waiting_unloaded", timeAlignment), ...
    'Color', workflowPhaseDisplayColor("waiting_unloaded", timeAlignment));
set(monitor.calibrationText, 'String', ...
    makeGatewayTimeAlignmentStatusText(timeAlignment, cfg));
updateSessionButtonStates(monitor, "waiting_unloaded", timeAlignment);
drawnow;

end

function monitor = showAnalysisFigureInitialization(monitor)

if ~isfield(monitor, 'enabled') || ~monitor.enabled || ...
        ~isfield(monitor, 'fig') || isempty(monitor.fig) || ~isvalid(monitor.fig)
    return;
end

set(monitor.gatewayStatusText, ...
    'String', '正在初始化轨迹窗口，完成后再订阅 MQTT...', ...
    'ForegroundColor', [0.15 0.28 0.55]);
set(monitor.phaseText, ...
    'String', 'Preparing analysis figures before data capture', ...
    'Color', [0.15 0.28 0.55]);
drawnow;

end

function monitor = showSensorFrameFault(monitor, message)

if ~isfield(monitor, 'enabled') || ~monitor.enabled || ...
        ~isfield(monitor, 'fig') || isempty(monitor.fig) || ~isvalid(monitor.fig)
    return;
end

faultColor = [0.75 0.05 0.05];
set(monitor.fig, 'Name', '传感器帧头异常 - 当前会话已停止');
set(monitor.phaseText, ...
    'String', '传感器帧头异常：需要手动重启鞋子', ...
    'Color', faultColor);
set(monitor.statusText, ...
    'String', sprintf('SENSOR FRAME HEADER ERROR\nSESSION STOPPED'), ...
    'Color', faultColor);
set(monitor.calibrationText, ...
    'String', char(message), ...
    'Color', faultColor, ...
    'FontSize', 10);
set(monitor.gatewayStatusText, ...
    'String', '当前会话已停止，请重启鞋子和程序', ...
    'ForegroundColor', faultColor);
updateSessionButtonStates(monitor, "finished");
drawnow;

try
    errordlg(char(message), '需要重启鞋子');
catch
end

end

function monitor = updateLatencyMonitor(monitor, state, logger, rawLogger, ...
        stepMetricsLogger, trajectoryLogger, rb, session, timeAlignment, cfg)

if ~isfield(monitor, 'enabled') || ~monitor.enabled
    return;
end

if ~isfield(monitor, 'fig') || isempty(monitor.fig) || ~isvalid(monitor.fig)
    monitor = initLatencyMonitor(cfg);
    return;
end

if toc(monitor.lastUpdateTime) < cfg.monitor.refreshEverySec
    return;
end

avgLatencyMs = meanRecent(state.latencyMs);
latestLatencyMs = latestRecent(state.latencyMs, state.latencyCursor);
samplesPerSec = state.samplesProcessed / max(toc(logger.runtimeTic), 1e-6);
isWarn = rb.count > cfg.monitor.warnQueue || ...
    (isfinite(avgLatencyMs) && avgLatencyMs > cfg.monitor.warnLatencyMs);

if isWarn
    fg = [0.75 0.05 0.05];
else
    fg = [0.00 0.45 0.18];
end

status = sprintf([ ...
    'queue        : %d\n' ...
    'dropped      : %d\n' ...
    'stale frames : %d\n' ...
    'proc latest  : %.2f ms\n' ...
    'proc average : %.2f ms\n' ...
    'samples/sec  : %.1f\n' ...
    'formal rows  : %d\n' ...
    'raw rows     : %d\n' ...
    'step/traj    : %d / %d'], ...
    rb.count, rb.dropCount, state.staleFrames, latestLatencyMs, avgLatencyMs, ...
    samplesPerSec, logger.rowsWritten + logger.pendingCount, ...
    rawLogger.rowsWritten + rawLogger.pendingCount, ...
    getLoggerRowsWritten(stepMetricsLogger), ...
    getLoggerRowsWritten(trajectoryLogger));

set(monitor.statusText, 'String', status, 'Color', fg);
set(monitor.phaseText, ...
    'String', workflowPhaseDisplayName(session.phase, timeAlignment), ...
    'Color', workflowPhaseDisplayColor(session.phase, timeAlignment));
set(monitor.calibrationText, 'String', ...
    makeCalibrationStatusText(session, timeAlignment, cfg));
set(monitor.tapAlignmentCheckbox, 'Value', ...
    double(timeAlignment.mode == "tap"));
updateSessionButtonStates(monitor, session.phase, timeAlignment);
set(monitor.leftImage, 'CData', pressureToDisplayMatrix(state.left.latestPressure, 'left'));
set(monitor.rightImage, 'CData', pressureToDisplayMatrix(state.right.latestPressure, 'right'));
set([monitor.leftAx monitor.rightAx], 'CLim', cfg.monitor.pressureCLim);
monitor = updateMonitorAcceleration(monitor, state, cfg);
monitor.lastUpdateTime = tic;

end

function name = phaseDisplayName(phase)

switch string(phase)
    case "waiting_unloaded"
        name = 'Waiting: empty-shoe calibration';
    case "unloaded_calibration"
        name = 'Step 1/4: empty-shoe calibration';
    case "unloaded_complete"
        name = 'Step 1 complete: put on both shoes';
    case "worn_preparation"
        name = 'Step 2/4: worn standing preparation';
    case "ready_to_record"
        name = 'Ready: formal recording can start';
    case "recording"
        name = 'Recording and analysis active';
    case "finished"
        name = 'Recording finished';
    otherwise
        name = char(string(phase));
end

end

function name = workflowPhaseDisplayName(phase, timeAlignment)

if string(phase) == "waiting_unloaded" && ~timeAlignment.ready
    switch string(timeAlignment.status)
        case "waiting"
            name = '硬板敲击对齐：准备好后点击按钮';
        case "collecting"
            if timeAlignment.mode == "tap"
                name = '硬板敲击对齐：现在开始敲击';
            else
                name = '正在自动关联左右脚时间';
            end
        case "failed"
            name = '硬板敲击对齐失败：请停止并重试';
        otherwise
            name = '正在等待左右脚时间对齐';
    end
else
    name = phaseDisplayName(phase);
end

end

function color = workflowPhaseDisplayColor(phase, timeAlignment)

if string(phase) == "waiting_unloaded" && ~timeAlignment.ready && ...
        timeAlignment.status == "failed"
    color = [0.75 0.05 0.05];
elseif timeAlignment.ready && string(phase) == "waiting_unloaded"
    color = [0.00 0.45 0.18];
else
    color = phaseDisplayColor(phase);
end

end

function color = phaseDisplayColor(phase)

switch string(phase)
    case {"unloaded_complete", "ready_to_record"}
        color = [0.00 0.45 0.18];
    case "recording"
        color = [0.75 0.05 0.05];
    case "finished"
        color = [0.25 0.25 0.25];
    otherwise
        color = [0.15 0.28 0.55];
end

end

function status = makeGatewayTimeAlignmentStatusText(timeAlignment, cfg)

leftCount = numel(timeAlignment.observations.left.gatewayT);
rightCount = numel(timeAlignment.observations.right.gatewayT);

if timeAlignment.ready
    spreadMs = 1000 * getScalarOrDefault( ...
        timeAlignment.result, 'qualitySpreadSec', NaN);
    if timeAlignment.mode == "tap"
        status = sprintf([ ...
            '敲击采集已经结束，请不要再敲。左右脚时间对齐成功，' ...
            '可以开始“不穿鞋校准”。\n右脚时间校正 %+0.3f ms，配对离散度 %.3f ms。'], ...
            1000 * timeAlignment.rightToLeftOffsetSec, spreadMs);
    else
        status = sprintf([ ...
            '未启用硬板敲击：自动时间关联已完成。\n' ...
            '右脚时间校正 %+0.3f ms，估计离散度 %.3f ms。'], ...
            1000 * timeAlignment.rightToLeftOffsetSec, spreadMs);
    end
    return;
end

if timeAlignment.mode == "passive"
    target = cfg.timeAlignment.passiveDurationSec;
    leftDuration = localSampleDuration( ...
        timeAlignment.observations.left.arrivalT);
    rightDuration = localSampleDuration( ...
        timeAlignment.observations.right.arrivalT);
    status = sprintf([ ...
        '未启用硬板敲击：正在自动采集左右脚到达时序，请保持设备正常输出。\n' ...
        '左/右样本 %d/%d，已采集 %.1f/%.1f 秒，目标 %.1f 秒。'], ...
        leftCount, rightCount, leftDuration, rightDuration, target);
elseif timeAlignment.status == "collecting"
    elapsed = 0;
    latestArrival = [ ...
        timeAlignment.observations.left.arrivalT; ...
        timeAlignment.observations.right.arrivalT];
    if isfinite(timeAlignment.startedArrivalT) && ~isempty(latestArrival)
        elapsed = max(latestArrival) - timeAlignment.startedArrivalT;
    end
    remaining = max(0, cfg.timeAlignment.tapDurationSec - elapsed);
    status = sprintf([ ...
        '现在开始敲：请连续敲击硬板 4-6 次，每次间隔约 0.5-1 秒；' ...
        '敲够后立即停止。\n无需持续敲到倒计时结束，系统将在 %.1f 秒后自动完成。' ...
        ' 左/右 IMU 样本 %d/%d。'], ...
        remaining, leftCount, rightCount);
elseif timeAlignment.status == "failed"
    status = sprintf([ ...
        '敲击采集已经结束，请停止敲击。本次未得到稳定的冲击配对，' ...
        '请点击按钮重试。\n原因：%s'], ...
        char(string(timeAlignment.statusMessage)));
else
    status = [ ...
        '硬板敲击已启用：请把两只空鞋放在同一块硬板上。现在先不要敲。' newline ...
        '点击旁边的“开始敲击时间对齐”后，看到“现在开始敲击”再敲。'];
end

end

function status = makeCalibrationStatusText(session, timeAlignment, cfg)

message = char(session.statusMessage);
alignment = makeGatewayTimeAlignmentStatusText(timeAlignment, cfg);
switch string(session.phase)
    case "unloaded_calibration"
        left = makeCollectorProgressLine( ...
            'Left', session.unloaded.left, ...
            cfg.calib.unloadedDurationSec, cfg.calib.unloadedMinImuSamples, ...
            cfg.calib.unloadedMinPressureSamples);
        right = makeCollectorProgressLine( ...
            'Right', session.unloaded.right, ...
            cfg.calib.unloadedDurationSec, cfg.calib.unloadedMinImuSamples, ...
            cfg.calib.unloadedMinPressureSamples);
        issue = latestCalibrationIssue( ...
            session.unloaded.left, session.unloaded.right);
        status = sprintf('%s\n%s\n%s\n%s\n%s', ...
            alignment, message, left, right, issue);

    case "worn_preparation"
        left = makeCollectorProgressLine( ...
            'Left', session.worn.left, ...
            cfg.calib.wornDurationSec, cfg.calib.wornMinImuSamples, ...
            cfg.calib.wornMinPressureSamples);
        right = makeCollectorProgressLine( ...
            'Right', session.worn.right, ...
            cfg.calib.wornDurationSec, cfg.calib.wornMinImuSamples, ...
            cfg.calib.wornMinPressureSamples);
        issue = latestCalibrationIssue(session.worn.left, session.worn.right);
        status = sprintf('%s\n%s\n%s\n%s\n%s', ...
            alignment, message, left, right, issue);

    otherwise
        if isempty(message)
            status = alignment;
        else
            status = sprintf('%s\n%s', alignment, message);
        end
end

end

function line = makeCollectorProgressLine(label, collector, ...
        targetDuration, targetImuSamples, targetPressureSamples)

if collector.complete
    line = sprintf('%-5s: complete', label);
    return;
end

imuDuration = localSampleDuration(collector.imuT);
progress = min(100, 100 * imuDuration / max(targetDuration, eps));
line = sprintf('%-5s: %5.1f%%  IMU %d/%d  pressure %d/%d', ...
    label, progress, numel(collector.imuT), targetImuSamples, ...
    numel(collector.pressureT), targetPressureSamples);

end

function issue = latestCalibrationIssue(leftCollector, rightCollector)

issue = '';
if strlength(string(leftCollector.lastIssue)) > 0
    issue = ['Left: ' char(leftCollector.lastIssue)];
end
if strlength(string(rightCollector.lastIssue)) > 0
    if isempty(issue)
        issue = ['Right: ' char(rightCollector.lastIssue)];
    else
        issue = sprintf('%s\nRight: %s', issue, char(rightCollector.lastIssue));
    end
end

end

function duration = localSampleDuration(t)

if numel(t) < 2
    duration = 0;
else
    duration = max(0, t(end) - t(1));
end

end

function updateSessionButtonStates(monitor, phase, timeAlignment)

phase = string(phase);
if nargin < 3 || isempty(timeAlignment)
    alignmentReady = true;
    tapMode = false;
    tapStatus = "";
    tapAvailable = false;
else
    alignmentReady = logical(timeAlignment.ready);
    tapMode = timeAlignment.mode == "tap";
    tapStatus = string(timeAlignment.status);
    tapAvailable = tapMode && ismember(tapStatus, ...
        ["waiting" "failed" "ready"]);
end
if isfield(monitor, 'tapAlignmentButton') && isvalid(monitor.tapAlignmentButton)
    if ~tapMode
        tapButtonText = '硬板敲击未启用';
    elseif tapStatus == "collecting"
        tapButtonText = '正在采集，请连续敲击';
    elseif tapStatus == "failed"
        tapButtonText = '敲击失败，点击重试';
    elseif alignmentReady
        tapButtonText = '重新敲击时间对齐';
    else
        tapButtonText = '开始敲击时间对齐';
    end
    set(monitor.tapAlignmentButton, ...
        'String', tapButtonText, ...
        'Enable', onOff(phase == "waiting_unloaded" && tapAvailable));
end
set(monitor.unloadedButton, 'Enable', onOff( ...
    alignmentReady && ~ismember(phase, ["recording" "finished"])));
set(monitor.wornButton, 'Enable', onOff(phase == "unloaded_complete"));
set(monitor.startButton, 'Enable', onOff(phase == "ready_to_record"));
set(monitor.stopButton, 'Enable', onOff(phase == "recording"));

end

function monitor = resetMonitorAccelerationHistory(monitor)

if ~isstruct(monitor)
    return;
end
monitor.accT = [];
monitor.leftAccNorm = [];
monitor.rightAccNorm = [];
if isfield(monitor, 'leftAccLine') && isvalid(monitor.leftAccLine)
    set(monitor.leftAccLine, 'XData', nan, 'YData', nan);
end
if isfield(monitor, 'rightAccLine') && isvalid(monitor.rightAccLine)
    set(monitor.rightAccLine, 'XData', nan, 'YData', nan);
end

end

function value = onOff(tf)

if tf
    value = 'on';
else
    value = 'off';
end

end

function queueGaitSessionCommand(appdataKey, command)

setappdata(0, appdataKey, char(command));

end

function monitor = showSessionTerminalState(monitor, session)

if ~isstruct(monitor) || ~isfield(monitor, 'fig') || ...
        isempty(monitor.fig) || ~isvalid(monitor.fig)
    return;
end

set(monitor.phaseText, 'String', phaseDisplayName(session.phase), ...
    'Color', phaseDisplayColor(session.phase));
set(monitor.calibrationText, 'String', char(session.statusMessage));
updateSessionButtonStates(monitor, session.phase);
set(monitor.fig, 'Name', 'Gait recording finished');
drawnow;

end

function monitor = updateMonitorAcceleration(monitor, state, cfg)

if ~isfield(monitor, 'accAx') || isempty(monitor.accAx) || ~isvalid(monitor.accAx)
    return;
end

leftAcc = getLatestAccNorm(state.left.latestImu);
rightAcc = getLatestAccNorm(state.right.latestImu);

if ~isfinite(leftAcc) && ~isfinite(rightAcc)
    return;
end

sensorT = getLatestImuSensorTimestamp(state);
if ~isfinite(sensorT)
    return;
end

monitor.accT(end + 1) = sensorT;
monitor.leftAccNorm(end + 1) = leftAcc;
monitor.rightAccNorm(end + 1) = rightAcc;

maxPoints = max(20, round(getNumericField(cfg.monitor, 'accelMaxPoints', 250)));
if numel(monitor.accT) > maxPoints
    idx = (numel(monitor.accT) - maxPoints + 1):numel(monitor.accT);
    monitor.accT = monitor.accT(idx);
    monitor.leftAccNorm = monitor.leftAccNorm(idx);
    monitor.rightAccNorm = monitor.rightAccNorm(idx);
end

tt = monitor.accT - monitor.accT(1);
set(monitor.leftAccLine, 'XData', tt, 'YData', monitor.leftAccNorm);
set(monitor.rightAccLine, 'XData', tt, 'YData', monitor.rightAccNorm);
ylim(monitor.accAx, cfg.monitor.accelYLim);

if ~isempty(tt)
    xEnd = max(5, tt(end));
    xStart = max(0, xEnd - 5);
    set(monitor.accAx, 'XLim', [xStart xEnd]);
end

end

function n = getLoggerRowsWritten(logger)

if isstruct(logger) && isfield(logger, 'rowsWritten') && isfield(logger, 'pendingCount')
    n = logger.rowsWritten + logger.pendingCount;
else
    n = 0;
end

end

function accNorm = getLatestAccNorm(imuMsg)

accNorm = NaN;
if isempty(imuMsg) || ~isstruct(imuMsg) || ~isfield(imuMsg, 'data')
    return;
end

acc = getVec3OrDefault(imuMsg.data, 'acc_g');
if any(isfinite(acc))
    accNorm = norm(acc);
end

end

function formatPressureAxes(ax, xLabels, xLabelText)

axis(ax, 'image');
set(ax, ...
    'XTick', 1:4, ...
    'XTickLabel', xLabels, ...
    'YTick', [1 12], ...
    'YTickLabel', {'Heel', 'Toe'}, ...
    'YDir', 'normal', ...
    'FontSize', 8, ...
    'TickLength', [0 0]);
xlabel(ax, xLabelText);
box(ax, 'on');

end

function M = pressureToDisplayMatrix(P, footName)

P = double(P(:).');
if numel(P) < 48
    M = nan(12, 4);
    return;
end

% Physical columns are medial -> lateral under the corrected sensor layout:
% 37:48, 25:36, 13:24, 1:12.  Rows are heel -> toe.
M = [P(37:48).' P(25:36).' P(13:24).' P(1:12).'];

% In the left-foot view, the medial side is on the right side of screen.
if strcmpi(footName, 'left')
    M = fliplr(M);
end

end

function row = makeLowLatencyPressureCsvRow(msg, footName, imuAgeSec, ...
        latencyMs, P, g, state, includePressure)

row = sprintf('%s%s,%.3f,%.3f,', ...
    makeMessageTimeCsvPrefix(msg), footName, imuAgeSec * 1000, latencyMs);

row = [row sprintf(['%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,' ...
    '%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,' ...
    '%.6f,%d,%d,%d,%d,%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f'], ...
    g.total, g.heel, g.mid, g.fore, g.toe, g.medial, g.lateral, ...
    g.R_heel, g.R_mid, g.R_fore, g.R_toe, g.R_foreToe, g.R_medial, g.R_lateral, ...
    g.COPxNorm, g.COPyNorm, g.loadIndex, ...
    logicalTo01(g.contact), logicalTo01(g.heelStrike), logicalTo01(g.heelOff), ...
    logicalTo01(g.pushOff), logicalTo01(g.toeOff), logicalTo01(g.zuptActive), ...
    g.stepCount, state.stepCount, g.vel(1), g.vel(2), g.pos(1), g.pos(2))];

if includePressure
    row = [row sprintf(',%.6g', P)];
end

end

function prefix = makeMessageTimeCsvPrefix(msg)

prefix = sprintf('%.6f,%s,%.6f,%s,%.6f,%s,%s,%d,%.3f,', ...
    getScalarOrDefault(msg, 'aligned_time_sec', ...
        getScalarOrDefault(msg, 'recv_time_sec', NaN)), ...
    csvEscapeLocal(getFieldOrDefault(msg, 'aligned_time_str', ...
        getFieldOrDefault(msg, 'recv_time_str', ""))), ...
    getScalarOrDefault(msg, 'gateway_time_sec', NaN), ...
    csvEscapeLocal(getFieldOrDefault(msg, 'gateway_time_str', "")), ...
    getScalarOrDefault(msg, 'arrival_time_sec', NaN), ...
    csvEscapeLocal(getFieldOrDefault(msg, 'arrival_time_str', "")), ...
    csvEscapeLocal(getFieldOrDefault(msg, 'time_alignment_method', "")), ...
    logicalTo01(getScalarOrDefault(msg, 'time_alignment_ready', false)), ...
    1000 * getScalarOrDefault(msg, 'time_alignment_offset_sec', 0));

end

function text = serializeImuDecodedFields(imuData)

accG = getVectorOrDefault(imuData, 'acc_g', [NaN NaN NaN]);
qWxyz = getVectorOrDefault(imuData, 'q_wxyz', [NaN NaN NaN NaN]);
accMs2 = getVectorOrDefault(imuData, 'acc_ms2', [NaN NaN NaN]);

values = [ ...
    getScalarOrDefault(imuData, 'tag', NaN), ...
    getScalarOrDefault(imuData, 'main_status', getScalarOrDefault(imuData, 'status', NaN)), ...
    getScalarOrDefault(imuData, 'status_ext', NaN), ...
    getScalarOrDefault(imuData, 'data_bitmap', NaN), ...
    accMs2, accG, qWxyz, ...
    getScalarOrDefault(imuData, 'crc', NaN)];

text = sprintf('%.9g,', values);
text = text(1:end-1);

end

function v = getScalarOrDefault(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    raw = double(s.(fieldName));
    v = raw(1);
else
    v = defaultValue;
end

end

function v = getFieldOrDefault(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    v = s.(fieldName);
else
    v = defaultValue;
end

end

function logger = appendLowLatencyCsvRow(logger, row, cfg)

logger.pendingCount = logger.pendingCount + 1;
logger.pending{logger.pendingCount} = row;

if logger.pendingCount >= cfg.log.flushEveryRows
    logger = flushLowLatencyCsvLogger(logger);
end

end

function logger = maybeFlushLowLatencyCsvLogger(logger, flushEverySec)

if toc(logger.lastFlushTime) >= flushEverySec
    logger = flushLowLatencyCsvLogger(logger);
end

end

function logger = flushLowLatencyCsvLogger(logger)

if logger.pendingCount <= 0
    logger.lastFlushTime = tic;
    return;
end

for i = 1:logger.pendingCount
    fprintf(logger.fid, '%s\n', logger.pending{i});
end

logger.rowsWritten = logger.rowsWritten + logger.pendingCount;
logger.pending(1:logger.pendingCount) = {[]};
logger.pendingCount = 0;
logger.lastFlushTime = tic;

end

function cleanupLowLatency(logger, decodedLoggers, rawLogger, stepMetricsLogger, trajectoryLogger, cfg)

try
    logger = flushLowLatencyCsvLogger(logger);
    if isfield(logger, 'fid') && logger.fid > 0
        fclose(logger.fid);
    end
catch
end

try
    decodedLoggers.imu = flushOneDecodedSensorLogger(decodedLoggers.imu);
    decodedLoggers.pressure = flushOneDecodedSensorLogger(decodedLoggers.pressure);
    if isfield(decodedLoggers.imu, 'fid') && decodedLoggers.imu.fid > 0
        fclose(decodedLoggers.imu.fid);
    end
    if isfield(decodedLoggers.pressure, 'fid') && decodedLoggers.pressure.fid > 0
        fclose(decodedLoggers.pressure.fid);
    end
catch
end

try
    rawLogger = flushOptionalRawLogger(rawLogger);
    if isfield(rawLogger, 'fid') && rawLogger.fid > 0
        fclose(rawLogger.fid);
    end
catch
end

try
    stepMetricsLogger = flushOptionalStepMetricsLogger(stepMetricsLogger);
    if isfield(stepMetricsLogger, 'fid') && stepMetricsLogger.fid > 0
        fclose(stepMetricsLogger.fid);
    end
catch
end

try
    trajectoryLogger = flushOptionalTrajectoryStateLogger(trajectoryLogger);
    if isfield(trajectoryLogger, 'fid') && trajectoryLogger.fid > 0
        fclose(trajectoryLogger.fid);
    end
catch
end

if isfield(cfg, 'queue') && isfield(cfg.queue, 'appdataKey') && isappdata(0, cfg.queue.appdataKey)
    rmappdata(0, cfg.queue.appdataKey);
end
if isfield(cfg, 'control') && isfield(cfg.control, 'appdataKey') && ...
        isappdata(0, cfg.control.appdataKey)
    rmappdata(0, cfg.control.appdataKey);
end

disp('Low-latency monitor stopped.');

end

function batch = keepLatestPerTopic(batch)

if isempty(batch)
    return;
end

topics = strings(numel(batch), 1);
for i = 1:numel(batch)
    topics(i) = string(batch{i}.Topic);
end

[~, lastIdx] = unique(flipud(topics), 'stable');
keepIdx = numel(batch) - lastIdx + 1;
keepIdx = sort(keepIdx);
batch = batch(keepIdx);

end

function q = getQuaternionOrDefault(imuData, defaultQ)

if isstruct(imuData) && isfield(imuData, 'q_wxyz') && numel(imuData.q_wxyz) >= 4
    q = normalizeQuaternion(double(imuData.q_wxyz(1:4)));
else
    q = defaultQ;
end

end

function v = getVectorOrDefault(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && numel(s.(fieldName)) >= numel(defaultValue)
    v = double(s.(fieldName)(1:numel(defaultValue)));
else
    v = defaultValue;
end

v = v(:).';

end

function q = normalizeQuaternion(q)

q = double(q(:).');
n = norm(q);
if ~isfinite(n) || n < 1e-12
    q = [1 0 0 0];
else
    q = q / n;
end

end

function y = logicalTo01(x)

y = double(logical(x));

end

function m = meanRecent(x)

x = x(isfinite(x));
if isempty(x)
    m = NaN;
else
    m = mean(x);
end

end

function v = latestRecent(x, cursor)

if isempty(x) || cursor <= 0 || cursor > numel(x) || ~isfinite(x(cursor))
    finiteValues = x(isfinite(x));
    if isempty(finiteValues)
        v = NaN;
    else
        v = finiteValues(end);
    end
else
    v = x(cursor);
end


end
