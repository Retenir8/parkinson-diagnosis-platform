function row = formatDecodedPressureCsvRow(msg, phase, latencyMs, streamAccepted, gaitCfg, activeThreshold)
% formatDecodedPressureCsvRow  Serialize one decoded 48-channel pressure frame.

P = double(msg.data.values(:).');
if numel(P) ~= 48
    error('PressureFrame:InvalidChannelCount', ...
        'Expected 48 pressure channels, received %d.', numel(P));
end

region = computePressureRegions48(P, gaitCfg);
activeSensorCount = sum(P > activeThreshold);
maxPressure = max(P);

row = sprintf(['%.6f,%s,%.6f,%s,%.6f,%s,%s,%d,%.3f,%s,%s,%.3f,%d,' ...
    '%.6g,%d,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6f,%.6f,%.6f'], ...
    getScalarOr(msg, 'aligned_time_sec', msg.recv_time_sec), ...
    csvEscapeValue(getFieldOr(msg, 'aligned_time_str', msg.recv_time_str)), ...
    getScalarOr(msg, 'gateway_time_sec', NaN), ...
    csvEscapeValue(getFieldOr(msg, 'gateway_time_str', "")), ...
    getScalarOr(msg, 'arrival_time_sec', NaN), ...
    csvEscapeValue(getFieldOr(msg, 'arrival_time_str', "")), ...
    csvEscapeValue(getFieldOr(msg, 'time_alignment_method', "")), ...
    logical(getScalarOr(msg, 'time_alignment_ready', false)), ...
    1000 * getScalarOr(msg, 'time_alignment_offset_sec', 0), ...
    char(string(msg.foot)), csvEscapeValue(phase), latencyMs, ...
    logical(streamAccepted), ...
    region.total, activeSensorCount, maxPressure, ...
    region.heel, region.mid, region.fore, region.toe, ...
    region.medial, region.lateral, region.copXNorm, region.copYNorm);
row = [row sprintf(',%.6g', P)];

end

function value = getScalarOr(s, fieldName, defaultValue)

value = getFieldOr(s, fieldName, defaultValue);
value = double(value(1));

end

function value = getFieldOr(s, fieldName, defaultValue)

if isstruct(s) && isfield(s, fieldName) && ~isempty(s.(fieldName))
    value = s.(fieldName);
else
    value = defaultValue;
end

end

function out = csvEscapeValue(value)

out = char(string(value));
out = strrep(out, '"', '""');
if contains(out, ',') || contains(out, '"') || ...
        contains(out, newline) || contains(out, sprintf('\r'))
    out = ['"' out '"'];
end

end
