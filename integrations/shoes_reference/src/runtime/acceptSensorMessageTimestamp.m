function [lastT, accepted] = acceptSensorMessageTimestamp(lastT, msg)
% acceptSensorMessageTimestamp  Enforce monotonic device time per sensor stream.

accepted = false;
if ~isstruct(msg) || ~isfield(msg, 'foot') || ...
        ~isfield(msg, 'sensor_type') || ~isfield(msg, 'recv_time_sec')
    return;
end

foot = char(string(msg.foot));
sensorType = char(string(msg.sensor_type));
t = double(msg.recv_time_sec);
if ~isscalar(t) || ~isfinite(t) || ...
        ~ismember(foot, {'left', 'right'}) || ...
        ~ismember(sensorType, {'imu', 'pressure'})
    return;
end

if ~isstruct(lastT)
    lastT = struct();
end
if ~isfield(lastT, foot) || ~isstruct(lastT.(foot))
    lastT.(foot) = struct();
end
if isfield(lastT.(foot), sensorType)
    previousT = double(lastT.(foot).(sensorType));
else
    previousT = NaN;
end

if isfinite(previousT) && t <= previousT
    return;
end

lastT.(foot).(sensorType) = t;
accepted = true;

end
