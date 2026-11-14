function imu = decodeIMUFrameFromStream(bytes)
% decodeIMUFrameFromStream  Decode the newest valid HI83 frame in a byte stream.

[~, decoded, ~, errors] = parseIMUFrameStream(uint8(bytes(:).'));
if ~isempty(decoded)
    imu = decoded{end};
    return;
end

if isempty(errors)
    detail = 'No complete HI83 frame was found.';
else
    detail = errors{end};
end
error('decodeIMUFrameFromStream:NoValidFrame', ...
    'No valid HI83 frame in MQTT payload: %s', detail);

end
