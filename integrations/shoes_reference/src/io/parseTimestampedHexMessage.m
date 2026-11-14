%% =========================

% 4 解析 [timestamp]HEX...：parseTimestampedHexMessage.m
%
%
%

% ==========================

function out = parseTimestampedHexMessage(msgStr)
% 输入示例:
% [2026-06-19 21:59:31.277]5A A5 4C 00 4E FF ...
% 末尾可带换行，HEX 中间也允许空白字符

if isstring(msgStr)
    msgStr = char(msgStr);
elseif isa(msgStr, 'uint8')
    msgStr = char(msgStr(:).');
end

% 去掉常见不可见字符
msgStr = strrep(msgStr, char(0), '');
msgStr = strrep(msgStr, char(65279), '');
msgStr = strtrim(msgStr);


lb = find(msgStr == '[', 1, 'first');
rb = find(msgStr == ']', 1, 'first');

if isempty(lb) || isempty(rb) || rb <= lb
    error('parseTimestampedHexMessage:BadFormat', ...
        'Invalid message format in parseTimestampedHexMessage. Expect [timestamp]HEX...');
end

recvTimeStr = strtrim(msgStr(lb + 1 : rb - 1));
hexStr = strtrim(msgStr(rb + 1 : end));

if isempty(hexStr)
    error('parseTimestampedHexMessage:EmptyHex', ...
        'HEX payload is empty.');
end

% 支持空格、Tab、回车、换行分隔的 HEX
hexStrClean = regexprep(hexStr, '\s+', '');

if isempty(regexp(hexStrClean, '^[0-9A-Fa-f]+$', 'once'))
    error('parseTimestampedHexMessage:NonHex', ...
        'HEX payload contains non-hex characters.');
end

if mod(numel(hexStrClean), 2) ~= 0
    error('parseTimestampedHexMessage:OddHexLength', ...
        'HEX payload length must be even, got %d hex chars.', numel(hexStrClean));
end

recvTimeDt = datetime(recvTimeStr, ...
    'InputFormat', 'yyyy-MM-dd HH:mm:ss.SSS');

recvTimeSec = posixtime(recvTimeDt);

bytes = uint8(sscanf(hexStrClean, '%2x').');

out.recv_time_str = recvTimeStr;
out.recv_time_dt  = recvTimeDt;
out.recv_time_sec = recvTimeSec;
out.hex_str = hexStr;
out.hex_str_clean = hexStrClean;
out.bytes   = bytes;
end
