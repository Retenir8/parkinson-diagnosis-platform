function deliverShoesSystemCommand(commandDir)
% Deliver one System command through the unmodified Shoes appdata contract.

key = 'gait_low_latency_session_command';
if ~isappdata(0, key) || strlength(string(getappdata(0, key))) ~= 0
    return;
end
files = dir(fullfile(commandDir, '*.json'));
if isempty(files)
    return;
end
[~, order] = sort({files.name});
commandFile = fullfile(commandDir, files(order(1)).name);
try
    payload = jsondecode(fileread(commandFile));
    command = string(payload.command);
    if ismember(command, ["start_time_alignment", "start_unloaded", ...
            "start_worn", "start_recording", "stop_recording", "shutdown"])
        setappdata(0, key, char(command));
    end
    delete(commandFile);
catch ME
    warning('ShoesBridge:CommandError', '%s', ME.message);
end
end
