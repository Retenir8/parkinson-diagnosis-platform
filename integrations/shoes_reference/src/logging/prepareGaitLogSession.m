function cfg = prepareGaitLogSession(cfg, projectDir, startDt)
% prepareGaitLogSession  Route one run's logs into a timestamped folder.

if nargin < 2 || isempty(projectDir)
    projectDir = fileparts(fileparts(fileparts(mfilename('fullpath'))));
end
if nargin < 3 || isempty(startDt)
    startDt = datetime('now');
end

stamp = char(startDt, 'yyyyMMdd_HHmmss_SSS');
logRootDir = fullfile(projectDir, 'log');
sessionDir = fullfile(logRootDir, stamp);
[created, message] = mkdir(sessionDir);
if ~created
    error('Cannot create session log directory %s: %s', sessionDir, message);
end

cfg.log.startDateTime = startDt;
cfg.log.sessionStamp = stamp;
cfg.log.rootDir = logRootDir;
cfg.log.sessionDir = sessionDir;
cfg.log = routeFileField(cfg.log, 'fileName', stamp, sessionDir);
cfg.log = routeFileField(cfg.log, 'manifestFileName', stamp, sessionDir);
cfg.log = routeFileField(cfg.log, 'manualTemplateFileName', stamp, sessionDir);
cfg.log = routeFileField(cfg.log, 'calibrationFileName', stamp, sessionDir);
cfg.log = routeFileField(cfg.log, 'timeAlignmentFileName', stamp, sessionDir);

if isfield(cfg, 'rawLog')
    cfg.rawLog.startDateTime = startDt;
    cfg.rawLog = routeFileField(cfg.rawLog, 'fileName', stamp, sessionDir);
end

if isfield(cfg, 'decodedLog')
    cfg.decodedLog.startDateTime = startDt;
    cfg.decodedLog = routeFileField(cfg.decodedLog, 'imuFileName', stamp, sessionDir);
    cfg.decodedLog = routeFileField(cfg.decodedLog, 'pressureFileName', stamp, sessionDir);
end

if isfield(cfg, 'trajectory')
    cfg.trajectory.stepMetricsLogStartDateTime = startDt;
    cfg.trajectory.stateLogStartDateTime = startDt;
    cfg.trajectory = routeFileField( ...
        cfg.trajectory, 'stepMetricsLogFileName', stamp, sessionDir);
    cfg.trajectory = routeFileField( ...
        cfg.trajectory, 'stateLogFileName', stamp, sessionDir);
end

end

function values = routeFileField(values, fieldName, stamp, sessionDir)

if ~isfield(values, fieldName) || isempty(values.(fieldName))
    return;
end

if strcmp(fieldName, 'fileName')
    baseFieldName = 'baseFileName';
else
    baseFieldName = [fieldName(1:end - 8) 'BaseFileName'];
end
values.(baseFieldName) = values.(fieldName);
values.(fieldName) = addTimestampToFileName( ...
    values.(fieldName), stamp, sessionDir);

end

function fileName = addTimestampToFileName(fileName, stamp, sessionDir)

[~, name, ext] = fileparts(char(fileName));
if isempty(ext)
    ext = '.csv';
end

fileName = fullfile(sessionDir, sprintf('%s_%s%s', name, stamp, ext));

end
