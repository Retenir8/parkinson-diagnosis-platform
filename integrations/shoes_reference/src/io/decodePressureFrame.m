%% =========================

% 9 压力帧解码：decodePressureFrame.m
%
%
%

% ==========================

function prs = decodePressureFrame(frame)

frame = uint8(frame(:)');
if numel(frame) ~= 99
    error('Pressure frame length must be 99 bytes, got %d', numel(frame));
end

if frame(1) ~= hex2dec('40')
    error('Invalid pressure header.');
end

if frame(2) == hex2dec('31')
    prs.foot = 'L';
elseif frame(2) == hex2dec('32')
    prs.foot = 'R';
else
    error('Unknown foot ID.');
end

checksumCalc = uint8(mod(sum(uint16(frame(1:98))), 256));
checksumFrame = frame(99);

if checksumCalc ~= checksumFrame
    error('Pressure checksum mismatch.');
end

values = zeros(1,48);
idx = 3;
for k = 1:48
    highByte = frame(idx);
    lowByte  = frame(idx+1);
    values(k) = double(uint16(highByte) * 256 + uint16(lowByte));
    idx = idx + 2;
end

prs.values = values;
prs.sum = sum(values);
prs.checksum = checksumFrame;
end
