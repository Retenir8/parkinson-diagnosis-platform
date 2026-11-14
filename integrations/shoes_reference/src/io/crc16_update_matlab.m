%% =========================

% 6 IMU CRC：crc16_update_matlab.m
%
%
%

% ==========================

function crc = crc16_update_matlab(crc, src)

crc = uint32(crc);
src = uint8(src);

for j = 1:numel(src)
    byte = uint32(src(j));
    crc = bitxor(crc, bitshift(byte, 8));

    for i = 1:8
        temp = bitshift(crc, 1);
        if bitand(crc, hex2dec('8000')) ~= 0
            temp = bitxor(temp, hex2dec('1021'));
        end
        crc = temp;
    end
end

crc = uint16(bitand(crc, hex2dec('FFFF')));
end
