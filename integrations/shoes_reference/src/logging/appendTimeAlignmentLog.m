function appendTimeAlignmentLog(fileName, eventName, state, note)
% appendTimeAlignmentLog  Append one gateway clock alignment event.

if nargin < 4
    note = "";
end

fid = fopen(fileName, 'a');
if fid < 0
    warning('Cannot append time alignment CSV file: %s', fileName);
    return;
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

result = getFieldOr(state, 'result', struct());
arrivalT = getScalarOr(state, 'completedArrivalT', ...
    getScalarOr(state, 'startedArrivalT', NaN));
status = string(getFieldOr(state, 'status', ""));
method = string(getFieldOr(state, 'mode', ""));
resultNote = string(getFieldOr(result, 'note', ""));
if strlength(string(note)) == 0
    note = resultNote;
end

row = sprintf('%.6f,%s,%s,%s,%s,%.9f,%.9f,%d,%d,%d,%.9f,%.9f,%s,%s,%s,%s', ...
    arrivalT, csvEscapeValue(eventName), csvEscapeValue(method), ...
    csvEscapeValue(status), ...
    csvEscapeValue(getFieldOr(state, 'referenceFoot', "left")), ...
    getScalarOr(result, 'rightToLeftOffsetSec', ...
        getScalarOr(state, 'rightToLeftOffsetSec', NaN)), ...
    getScalarOr(result, 'qualitySpreadSec', NaN), ...
    round(getScalarOr(result, 'leftSamples', 0)), ...
    round(getScalarOr(result, 'rightSamples', 0)), ...
    round(getScalarOr(result, 'pairCount', 0)), ...
    getScalarOr(result, 'leftArrivalMinusGatewaySec', NaN), ...
    getScalarOr(result, 'rightArrivalMinusGatewaySec', NaN), ...
    csvEscapeValue(formatVector(getFieldOr(result, 'offsetSamplesSec', []))), ...
    csvEscapeValue(formatVector(getFieldOr(result, 'leftPeakGatewayT', []))), ...
    csvEscapeValue(formatVector(getFieldOr(result, 'rightPeakGatewayT', []))), ...
    csvEscapeValue(note));
fprintf(fid, '%s\n', row);

end

function text = formatVector(values)

values = double(values(:));
if isempty(values)
    text = "";
else
    parts = compose('%.9f', values);
    text = strjoin(parts, ';');
end

end

function value = getFieldOr(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName))
    value = values.(fieldName);
else
    value = defaultValue;
end

end

function value = getScalarOr(values, fieldName, defaultValue)

value = getFieldOr(values, fieldName, defaultValue);
value = double(value(1));

end

function value = csvEscapeValue(value)

value = char(string(value));
value = strrep(value, '"', '""');
if contains(value, ',') || contains(value, '"') || ...
        contains(value, newline) || contains(value, sprintf('\r'))
    value = ['"' value '"'];
end

end
