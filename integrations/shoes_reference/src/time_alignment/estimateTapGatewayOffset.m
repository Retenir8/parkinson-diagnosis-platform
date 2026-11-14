function result = estimateTapGatewayOffset(left, right, cfg)
% estimateTapGatewayOffset  Align gateway clocks from paired board impacts.

if nargin < 3
    cfg = struct();
end

result = baseResult();
[leftPeaks, leftPeakSignal] = detectImpactPeaks(left, cfg);
[rightPeaks, rightPeakSignal] = detectImpactPeaks(right, cfg);
result.leftSamples = numel(getFieldOr(left, 'gatewayT', []));
result.rightSamples = numel(getFieldOr(right, 'gatewayT', []));

[leftIdx, rightIdx] = pairPeaksByArrival( ...
    leftPeaks.arrivalT, rightPeaks.arrivalT, ...
    getNumericField(cfg, 'tapPairArrivalToleranceSec', 0.25));
result.pairCount = numel(leftIdx);

minimumPairs = round(getNumericField(cfg, 'tapMinPairs', 3));
if result.pairCount < minimumPairs
    result.note = sprintf( ...
        'Detected %d/%d paired impacts; repeat with firmer, separated taps.', ...
        result.pairCount, minimumPairs);
    return;
end

leftGatewayT = leftPeaks.gatewayT(leftIdx);
rightGatewayT = rightPeaks.gatewayT(rightIdx);
offsetSamples = leftGatewayT - rightGatewayT;
offset = median(offsetSamples);
spread = 1.4826 * median(abs(offsetSamples - offset));
if ~isfinite(spread)
    spread = Inf;
end

maximumSpread = getNumericField(cfg, 'tapMaxOffsetSpreadSec', 0.05);
if spread > maximumSpread
    result.note = sprintf( ...
        'Impact offsets are inconsistent (robust spread %.1f ms).', ...
        spread * 1000);
    result.rightToLeftOffsetSec = offset;
    result.qualitySpreadSec = spread;
    result.leftPeakGatewayT = leftGatewayT;
    result.rightPeakGatewayT = rightGatewayT;
    result.offsetSamplesSec = offsetSamples;
    return;
end

result.success = true;
result.rightToLeftOffsetSec = offset;
result.qualitySpreadSec = spread;
result.leftPeakGatewayT = leftGatewayT;
result.rightPeakGatewayT = rightGatewayT;
result.offsetSamplesSec = offsetSamples;
result.note = sprintf( ...
    'Paired %d board impacts; left/right peak strengths %.1f/%.1f m/s^2.', ...
    result.pairCount, max(leftPeakSignal), max(rightPeakSignal));

end

function [peaks, selectedSignal] = detectImpactPeaks(observation, cfg)

peaks = struct('arrivalT', zeros(0, 1), 'gatewayT', zeros(0, 1));
selectedSignal = NaN;
if ~isstruct(observation) || ~isfield(observation, 'arrivalT') || ...
        ~isfield(observation, 'gatewayT') || ...
        ~isfield(observation, 'accNormMs2')
    return;
end

arrivalT = double(observation.arrivalT(:));
gatewayT = double(observation.gatewayT(:));
signal = double(observation.accNormMs2(:));
n = min([numel(arrivalT), numel(gatewayT), numel(signal)]);
arrivalT = arrivalT(1:n);
gatewayT = gatewayT(1:n);
signal = signal(1:n);
keep = isfinite(arrivalT) & isfinite(gatewayT) & isfinite(signal);
arrivalT = arrivalT(keep);
gatewayT = gatewayT(keep);
signal = signal(keep);
if numel(signal) < 3
    return;
end

[arrivalT, order] = sort(arrivalT);
gatewayT = gatewayT(order);
signal = signal(order);
activity = abs(signal - median(signal));
activityMedian = median(activity);
activityMad = 1.4826 * median(abs(activity - activityMedian));
threshold = max( ...
    getNumericField(cfg, 'tapMinPeakMs2', 3.0), ...
    activityMedian + getNumericField(cfg, 'tapSigmaMultiplier', 6.0) * ...
        max(activityMad, eps));

candidate = find( ...
    activity(2:end - 1) >= activity(1:end - 2) & ...
    activity(2:end - 1) > activity(3:end) & ...
    activity(2:end - 1) >= threshold) + 1;
if isempty(candidate)
    return;
end

[~, amplitudeOrder] = sort(activity(candidate), 'descend');
minimumSpacing = getNumericField(cfg, 'tapMinPeakSpacingSec', 0.35);
maximumPeaks = round(getNumericField(cfg, 'tapMaxPeaksPerFoot', 16));
selected = zeros(0, 1);
for k = 1:numel(amplitudeOrder)
    idx = candidate(amplitudeOrder(k));
    if isempty(selected) || all(abs(arrivalT(idx) - arrivalT(selected)) >= minimumSpacing)
        selected(end + 1, 1) = idx; %#ok<AGROW>
        if numel(selected) >= maximumPeaks
            break;
        end
    end
end

[~, chronologicalOrder] = sort(arrivalT(selected));
selected = selected(chronologicalOrder);
peaks.arrivalT = arrivalT(selected);
peaks.gatewayT = gatewayT(selected);
selectedSignal = activity(selected);

end

function [leftIdx, rightIdx] = pairPeaksByArrival(leftArrival, rightArrival, tolerance)

leftIdx = zeros(0, 1);
rightIdx = zeros(0, 1);
availableRight = true(numel(rightArrival), 1);
for i = 1:numel(leftArrival)
    candidate = find(availableRight);
    if isempty(candidate)
        break;
    end
    [distance, localIdx] = min(abs(rightArrival(candidate) - leftArrival(i)));
    if distance <= tolerance
        j = candidate(localIdx);
        leftIdx(end + 1, 1) = i; %#ok<AGROW>
        rightIdx(end + 1, 1) = j; %#ok<AGROW>
        availableRight(j) = false;
    end
end

end

function result = baseResult()

result = struct( ...
    'success', false, ...
    'method', "tap", ...
    'rightToLeftOffsetSec', NaN, ...
    'qualitySpreadSec', NaN, ...
    'leftSamples', 0, ...
    'rightSamples', 0, ...
    'pairCount', 0, ...
    'leftArrivalMinusGatewaySec', NaN, ...
    'rightArrivalMinusGatewaySec', NaN, ...
    'leftPeakGatewayT', zeros(0, 1), ...
    'rightPeakGatewayT', zeros(0, 1), ...
    'offsetSamplesSec', zeros(0, 1), ...
    'note', "");

end

function value = getFieldOr(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName)
    value = values.(fieldName);
else
    value = defaultValue;
end

end

function value = getNumericField(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName)) && isfinite(double(values.(fieldName)(1)))
    value = double(values.(fieldName)(1));
else
    value = defaultValue;
end

end
