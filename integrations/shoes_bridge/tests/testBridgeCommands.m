function tests = testBridgeCommands
tests = functiontests(localfunctions);
end

function testCommandQueueUsesOriginalAppdataKey(testCase)
commandDir = tempname;
mkdir(commandDir);
cleanupDir = onCleanup(@() cleanupCommandDir(commandDir)); %#ok<NASGU>
key = 'gait_low_latency_session_command';
setappdata(0, key, '');
cleanupKey = onCleanup(@() rmappdata(0, key)); %#ok<NASGU>
file = fullfile(commandDir, '000001.json');
writeCommand(file, 'start_unloaded');
deliverShoesSystemCommand(commandDir);
verifyEqual(testCase, string(getappdata(0, key)), "start_unloaded");
verifyFalse(testCase, isfile(file));
end

function testBusyCommandRemainsQueued(testCase)
commandDir = tempname;
mkdir(commandDir);
file = fullfile(commandDir, '000001.json');
writeCommand(file, 'start_recording');
cleanupDir = onCleanup(@() cleanupCommandDir(commandDir)); %#ok<NASGU>
key = 'gait_low_latency_session_command';
setappdata(0, key, 'start_worn');
cleanupKey = onCleanup(@() rmappdata(0, key)); %#ok<NASGU>
deliverShoesSystemCommand(commandDir);
verifyEqual(testCase, string(getappdata(0, key)), "start_worn");
verifyTrue(testCase, isfile(file));
end

function writeCommand(file, command)
fid = fopen(file, 'w');
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s', jsonencode(struct('command', command)));
end

function cleanupCommandDir(commandDir)
files = dir(fullfile(commandDir, '*.json'));
for i = 1:numel(files)
    delete(fullfile(commandDir, files(i).name));
end
rmdir(commandDir);
end
