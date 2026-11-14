function runShoesFromSystem(commandDir)
% runShoesFromSystem  Run the unmodified Shoes program with System commands.
%
% The timer writes only the existing root-appdata command key consumed by
% runMqttGaitLowLatency. Sensor decoding and all gait calculations remain in
% the SHA-256-mirrored Shoes source tree.

commandDir = char(string(commandDir));
if strcmp(commandDir, '--self-test')
    required = {'runMqttGaitLowLatency', 'setupGaitProject', ...
        'prepareGaitLogSession', 'deliverShoesSystemCommand', 'mqttclient', ...
        'decodeMqttSensorMessage', 'decodeIMUFrame', 'decodePressureFrame', ...
        'updateGaitSessionCalibration', 'updateTrajectoryEstimator'};
    for i = 1:numel(required)
        assert(exist(required{i}, 'file') ~= 0, ...
            'Shoes deployment is missing %s', required{i});
    end
    if isdeployed
        assert(strcmp(setupGaitProject(), ctfroot), ...
            'Shoes deployment path setup is incorrect.');
        previousLogRoot = getenv('MEDVISION_SHOES_LOG_ROOT');
        restoreLogRoot = onCleanup(@() setenv( ...
            'MEDVISION_SHOES_LOG_ROOT', previousLogRoot)); %#ok<NASGU>
        probeRoot = tempname;
        mkdir(probeRoot);
        setenv('MEDVISION_SHOES_LOG_ROOT', probeRoot);
        probeCfg.log.fileName = 'gait_state.csv';
        probeCfg = prepareGaitLogSession( ...
            probeCfg, tempdir, datetime(2026, 1, 1, 0, 0, 0));
        assert(strcmp(probeCfg.log.rootDir, probeRoot), ...
            'Shoes deployment log routing is incorrect.');
        rmdir(probeCfg.log.sessionDir);
        rmdir(probeRoot);
    end
    fprintf('SHOES_DEPLOYMENT_SELF_TEST_OK\n');
    return;
end
if exist(commandDir, 'dir') ~= 7
    mkdir(commandDir);
end

if ~isdeployed
    bridgeDir = fileparts(mfilename('fullpath'));
    sourceDir = fullfile(bridgeDir, '..', 'shoes_reference');
    previousDir = pwd;
    cleanupDir = onCleanup(@() cd(previousDir)); %#ok<NASGU>
    cd(sourceDir);
    addpath(sourceDir);
    cleanupPath = onCleanup(@() rmpath(sourceDir)); %#ok<NASGU>
end

watcher = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.2, ...
    'BusyMode', 'drop', 'TimerFcn', @(~, ~) deliverShoesSystemCommand(commandDir));
cleanupTimer = onCleanup(@() stopAndDeleteTimer(watcher)); %#ok<NASGU>
start(watcher);
runMqttGaitLowLatency();
end

function stopAndDeleteTimer(watcher)
if isvalid(watcher)
    stop(watcher);
    delete(watcher);
end
end
