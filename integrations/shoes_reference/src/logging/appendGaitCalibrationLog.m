function appendGaitCalibrationLog(fileName, eventName, foot, result, sensorT, note)
% appendGaitCalibrationLog  Append one calibration or workflow event.

if nargin < 3 || isempty(foot)
    foot = "";
end
if nargin < 4 || isempty(result)
    result = struct();
end
if nargin < 5
    sensorT = NaN;
end
if nargin < 6
    note = "";
end

fid = fopen(fileName, 'a');
if fid < 0
    warning('Cannot append calibration CSV file: %s', fileName);
    return;
end
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>

bodyBias = vectorField(result, 'bodyAccBias', 3);
bodyNoise = vectorField(result, 'bodyAccNoise', 3);
navBias = vectorField(result, 'accNavBias', 3);
standingCop = vectorField(result, 'standingCOP', 2);
q0 = vectorField(result, 'q0_wxyz', 4);
pressureZero = vectorField(result, 'pressureZero', 48);
pressureNoise = vectorField(result, 'pressureNoise', 48);

row = sprintf(['%.6f,%s,%s,%d,%d,%.6f,' ...
    '%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,' ...
    '%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,' ...
    '%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%s'], ...
    sensorT, csvEscapeValue(eventName), csvEscapeValue(foot), ...
    scalarField(result, 'imuSamples', 0), ...
    scalarField(result, 'pressureSamples', 0), ...
    scalarField(result, 'durationSec', NaN), ...
    bodyBias, bodyNoise, navBias, ...
    scalarField(result, 'standingTotalPressure', NaN), ...
    standingCop, q0, ...
    scalarField(result, 'angularRateP95Deg', NaN), ...
    scalarField(result, 'loadVariation', NaN), ...
    mean(pressureZero, 'omitnan'), max(pressureZero, [], 'omitnan'), ...
    csvEscapeValue(note));
row = [row sprintf(',%.9g', pressureZero) sprintf(',%.9g', pressureNoise)];
fprintf(fid, '%s\n', row);

end

function value = scalarField(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName))
    raw = double(values.(fieldName));
    value = raw(1);
else
    value = defaultValue;
end

end

function value = vectorField(values, fieldName, count)

value = nan(1, count);
if isstruct(values) && isfield(values, fieldName) && ...
        numel(values.(fieldName)) >= count
    raw = double(values.(fieldName));
    value = raw(1:count);
end
value = value(:).';

end

function value = csvEscapeValue(value)

value = char(string(value));
value = strrep(value, '"', '""');
if contains(value, ',') || contains(value, '"') || ...
        contains(value, newline) || contains(value, sprintf('\r'))
    value = ['"' value '"'];
end

end
