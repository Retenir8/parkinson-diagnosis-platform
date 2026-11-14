function validateMqttSensorFrameHeader(bytes, foot, sensorType)
% validateMqttSensorFrameHeader  Enforce the frame header at payload byte 1.

bytes = uint8(bytes(:).');
foot = lower(string(foot));
sensorType = lower(string(sensorType));

if sensorType == "imu"
    expected = uint8([hex2dec('5A') hex2dec('A5')]);
elseif sensorType == "pressure" && foot == "left"
    expected = uint8([hex2dec('40') hex2dec('31')]);
elseif sensorType == "pressure" && foot == "right"
    expected = uint8([hex2dec('40') hex2dec('32')]);
else
    error('gait:UnknownSensorStream', ...
        'Unknown sensor stream: foot=%s type=%s.', char(foot), char(sensorType));
end

if numel(bytes) >= 2
    actual = bytes(1:2);
    actualText = sprintf('%02X %02X', actual(1), actual(2));
else
    actual = bytes;
    if isempty(actual)
        actualText = '<empty>';
    else
        actualText = sprintf('%02X', actual(1));
    end
end

if numel(actual) ~= 2 || any(actual ~= expected)
    error('gait:SensorFrameHeaderMismatch', ...
        ['%s %s payload must start with %02X %02X immediately after ' ...
        'the timestamp; received %s.'], ...
        char(foot), char(sensorType), expected(1), expected(2), actualText);
end

end
