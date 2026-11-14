function msg = decodeMqttSensorMessage(topic, payload, cfg, rawMsg)
% decodeMqttSensorMessage
% Decode one MQTT sensor message.
%
% Topic format:
%   D2S/U/1/deviceId  -> IMU
%   D2S/U/0/deviceId  -> pressure
%
% Device id -> foot is configured by cfg.devices:
%   cfg.devices(1).id = "AABBCCDDEEFF";
%   cfg.devices(1).foot = "left";

if nargin < 3
    cfg = struct();
end
if nargin < 4
    rawMsg = struct();
end

%% Parse payload timestamp and HEX bytes
parsed = parseTimestampedHexMessage(payload);

if isfield(parsed, 'bytes')
    bytes = parsed.bytes;
else
    error('decodeMqttSensorMessage:MissingBytes', ...
        'parseTimestampedHexMessage must return parsed.bytes.');
end

bytes = uint8(bytes(:)');

%% Parse MQTT topic
rawTopic = string(topic);
parts = split(rawTopic, "/");

if numel(parts) ~= 4
    error('decodeMqttSensorMessage:BadTopicFormat', ...
        'Invalid topic format: %s', char(rawTopic));
end

if parts(1) ~= "D2S" || parts(2) ~= "U"
    error('decodeMqttSensorMessage:BadTopicPrefix', ...
        'Unknown topic prefix: %s', char(rawTopic));
end

topicType = parts(3);
deviceId = parts(4);

%% Topic type -> sensor type
switch topicType
    case "1"
        sensorType = "imu";
    case "0"
        sensorType = "pressure";
    otherwise
        error('decodeMqttSensorMessage:UnknownTopicType', ...
            'Unknown topic type "%s" in topic: %s', ...
            char(topicType), char(rawTopic));
end

%% Device id -> foot
foot = lookupFootByDeviceId(deviceId, cfg);

%% Decode sensor frame
validateMqttSensorFrameHeader(bytes, foot, sensorType);
switch sensorType
    case "imu"
        data = decodeIMUFrame(bytes);
    case "pressure"
        data = decodePressureFrame(bytes);
    otherwise
        error('decodeMqttSensorMessage:UnknownSensorType', ...
            'Unknown sensor type: %s', char(sensorType));
end

%% Keep gateway sample time separate from MQTT callback arrival time.
[arrivalSec, arrivalTimeStr] = getMqttArrivalTimestamp(rawMsg);
gatewayTimeSec = getParsedTime(parsed);
gatewayTimeStr = getParsedString(parsed, 'recv_time_str');
tSec = gatewayTimeSec;

%% Build message used by the rest of the project
msg = struct();

% 兼容旧流程/融合流程最关键的字段
msg.type = char(sensorType);     % <<< 关键：补 type
msg.foot = char(foot);
msg.t = tSec;                    % <<< 关键：补 t

% 保留你原来的字段
msg.topic = "gait/" + foot + "/" + sensorType;
msg.raw_topic = rawTopic;
msg.topic_type = topicType;
msg.device_id = deviceId;
msg.sensor_type = char(sensorType);

msg.data = data;
msg.bytes = bytes;
msg.raw_bytes = bytes;
msg.recv_time_sec = gatewayTimeSec;
msg.recv_time_str = gatewayTimeStr;
msg.arrival_time_sec = arrivalSec;
msg.arrival_time_str = arrivalTimeStr;
msg.gateway_time_sec = gatewayTimeSec;
msg.gateway_time_str = gatewayTimeStr;
msg.sensor_time_sec = gatewayTimeSec;

if isfield(parsed, 'recv_time_dt')
    msg.gateway_time_dt = parsed.recv_time_dt;
end

end

function tSec = getParsedTime(parsed)

if isfield(parsed, 'recv_time_sec')
    tSec = double(parsed.recv_time_sec);
elseif isfield(parsed, 'time_sec')
    tSec = double(parsed.time_sec);
elseif isfield(parsed, 'timestamp')
    tSec = double(parsed.timestamp);
elseif isfield(parsed, 't')
    tSec = double(parsed.t);
else
    tSec = NaN;
end

end

function value = getParsedString(parsed, fieldName)

if isfield(parsed, fieldName) && ~isempty(parsed.(fieldName))
    value = string(parsed.(fieldName));
else
    value = "";
end

end


function foot = lookupFootByDeviceId(deviceId, cfg)

deviceId = string(deviceId);

if ~isfield(cfg, 'devices') || isempty(cfg.devices)
    error('decodeMqttSensorMessage:MissingDeviceMap', ...
        ['Missing cfg.devices. Define cfg.devices(i).id and ', ...
         'cfg.devices(i).foot in the main script. Device id: %s'], ...
        char(deviceId));
end

foot = "";

for i = 1:numel(cfg.devices)
    if string(cfg.devices(i).id) == deviceId
        foot = string(cfg.devices(i).foot);
        break;
    end
end

if foot == ""
    knownIds = strings(1, numel(cfg.devices));
    for i = 1:numel(cfg.devices)
        knownIds(i) = string(cfg.devices(i).id);
    end

    error('decodeMqttSensorMessage:UnknownDeviceId', ...
        'Unknown device id "%s". Known device ids: %s', ...
        char(deviceId), char(strjoin(knownIds, ", ")));
end

if foot ~= "left" && foot ~= "right"
    error('decodeMqttSensorMessage:BadFootName', ...
        'Invalid foot "%s" for device id "%s". Use "left" or "right".', ...
        char(foot), char(deviceId));
end

end
