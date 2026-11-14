%% =========================

% 7 IMU 帧 CRC 计算：crc16_imu_frame.m
%
%
%

% ==========================

function crc = crc16_imu_frame(frame)
% CRC覆盖:
% frame(1:4) + frame(7:6+payloadLen)

frame = uint8(frame(:)');
if numel(frame) < 6
    error('Frame too short.');
end

payloadLen = typecast(uint8(frame(3:4)), 'uint16');
totalLen = 6 + double(payloadLen);

if numel(frame) < totalLen
    error('Incomplete IMU frame.');
end

crc = uint16(0);
crc = crc16_update_matlab(crc, frame(1:4));
crc = crc16_update_matlab(crc, frame(7:6+double(payloadLen)));
end
