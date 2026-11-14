function imu = decodeIMUFrame(frame)
% decodeIMUFrame  Decode HiPNUC HI83 variable data frame.
%
% Current device configuration:
%   frame type  : HI83
%   data_bitmap : 0x00000011
%   segments    : acc_b float32[3] in m/s^2, quat float32[4] in WXYZ order

frame = uint8(frame(:).');
if numel(frame) < 6
    error('decodeIMUFrame:FrameTooShort', ...
        'IMU frame must be at least 6 bytes, got %d.', numel(frame));
end

if ~(frame(1) == hex2dec('5A') && frame(2) == hex2dec('A5'))
    error('decodeIMUFrame:InvalidHeader', 'Invalid HI83 frame header.');
end

payloadLen = readUint16LE(frame, 3);
totalLen = 6 + double(payloadLen);
if numel(frame) ~= totalLen
    error('decodeIMUFrame:UnexpectedFrameLength', ...
        'HI83 frame length mismatch. payload=%d total=%d got=%d.', ...
        payloadLen, totalLen, numel(frame));
end

if payloadLen ~= 36
    error('decodeIMUFrame:UnexpectedPayloadLength', ...
        'Current HI83 config expects 36-byte payload, got %d.', payloadLen);
end

crcFrame = readUint16LE(frame, 5);
crcCalc = crc16_imu_frame(frame);
if crcCalc ~= crcFrame
    error('decodeIMUFrame:CrcMismatch', ...
        'HI83 CRC mismatch. calc=0x%04X frame=0x%04X.', crcCalc, crcFrame);
end

payload = frame(7:end);
tag = payload(1);
if tag ~= hex2dec('83')
    error('decodeIMUFrame:UnexpectedTag', ...
        'Expected HI83 tag 0x83, got 0x%02X.', tag);
end

dataBitmap = readUint32LE(payload, 5);
if dataBitmap ~= uint32(hex2dec('00000011'))
    error('decodeIMUFrame:UnsupportedDataBitmap', ...
        'Unsupported HI83 data_bitmap 0x%08X. Expected 0x00000011.', dataBitmap);
end

accMs2 = readFloat32VectorLE(payload, 9, 3);
qWxyz = readFloat32VectorLE(payload, 21, 4);
qWxyz = normalizeQuaternionLocal(qWxyz);

imu = struct();
imu.frame_type = 'HI83';
imu.tag = tag;
imu.main_status = readUint16LE(payload, 2);
imu.status = imu.main_status;
imu.status_ext = payload(4);
imu.data_bitmap = dataBitmap;
imu.acc_b_ms2 = accMs2;
imu.acc_ms2 = accMs2;
imu.acc_g = accMs2 / 9.80665;
imu.q_wxyz = qWxyz;
imu.crc = crcFrame;

% Compatibility fields for existing plotting/logging paths.  HI83 current
% bitmap does not include these segments, so keep them explicit NaN values.
imu.gyr_dps = [NaN NaN NaN];
imu.gyr_rads = [NaN NaN NaN];
imu.mag_uT = [NaN NaN NaN];
imu.euler_deg = [NaN NaN NaN];
imu.temperature = NaN;
imu.air_pressure = NaN;
imu.system_time = NaN;

end

function v = readUint16LE(bytes, idx)

v = typecast(uint8(bytes(idx:idx + 1)), 'uint16');

end

function v = readUint32LE(bytes, idx)

v = typecast(uint8(bytes(idx:idx + 3)), 'uint32');

end

function v = readFloat32VectorLE(bytes, idx, n)

v = zeros(1, n);
for k = 1:n
    j = idx + (k - 1) * 4;
    v(k) = typecast(uint8(bytes(j:j + 3)), 'single');
end
v = double(v);

end

function q = normalizeQuaternionLocal(q)

q = double(q(:).');
n = norm(q);
if ~isfinite(n) || n < 1e-12
    q = [1 0 0 0];
else
    q = q / n;
end

end
