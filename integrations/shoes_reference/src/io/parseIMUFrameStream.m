function [frames, decoded, buffer, errors] = parseIMUFrameStream(buffer)
% parseIMUFrameStream  Extract HI83 IMU frames from a serial byte buffer.
%
% Usage:
%   [frames, decoded, buffer, errors] = parseIMUFrameStream(buffer)
%
% The returned buffer contains only incomplete trailing bytes that should be
% prepended to the next serial read.  CRC failures discard the current frame
% header and continue searching, so the parser can resynchronise after noise.

buffer = uint8(buffer(:).');
frames = {};
decoded = {};
errors = {};

while numel(buffer) >= 6
    headerIdx = find(buffer(1:end-1) == hex2dec('5A') & ...
        buffer(2:end) == hex2dec('A5'), 1, 'first');

    if isempty(headerIdx)
        if buffer(end) == hex2dec('5A')
            buffer = buffer(end);
        else
            buffer = uint8([]);
        end
        return;
    end

    if headerIdx > 1
        buffer = buffer(headerIdx:end);
    end

    if numel(buffer) < 6
        return;
    end

    payloadLen = typecast(uint8(buffer(3:4)), 'uint16');
    totalLen = 6 + double(payloadLen);
    if totalLen < 6
        errors{end + 1} = 'Invalid payload length.'; %#ok<AGROW>
        buffer = buffer(2:end);
        continue;
    end

    if numel(buffer) < totalLen
        return;
    end

    frame = buffer(1:totalLen);
    try
        imu = decodeIMUFrame(frame);
        frames{end + 1} = frame; %#ok<AGROW>
        decoded{end + 1} = imu; %#ok<AGROW>
        buffer = buffer(totalLen + 1:end);
    catch ME
        errors{end + 1} = ME.message; %#ok<AGROW>
        buffer = buffer(2:end);
    end
end

end
