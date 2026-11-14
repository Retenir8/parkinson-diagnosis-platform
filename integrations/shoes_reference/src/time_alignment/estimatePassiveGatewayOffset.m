function result = estimatePassiveGatewayOffset(left, right, cfg)
% estimatePassiveGatewayOffset  Estimate the right clock offset from arrivals.
%
% The estimate uses only the difference between the two gateways. MATLAB
% arrival time supplies a temporary common reference and is not used as the
% formal sample timestamp.

if nargin < 3
    cfg = struct();
end

result = baseResult();
leftDelta = finiteArrivalMinusGateway(left);
rightDelta = finiteArrivalMinusGateway(right);
result.leftSamples = numel(leftDelta);
result.rightSamples = numel(rightDelta);

minimumSamples = getNumericField(cfg, 'passiveMinSamplesPerFoot', 100);
if numel(leftDelta) < minimumSamples || numel(rightDelta) < minimumSamples
    result.note = "Not enough samples for passive gateway alignment.";
    return;
end

leftCenter = median(leftDelta);
rightCenter = median(rightDelta);
leftSpread = robustSpread(leftDelta);
rightSpread = robustSpread(rightDelta);

result.success = true;
result.leftArrivalMinusGatewaySec = leftCenter;
result.rightArrivalMinusGatewaySec = rightCenter;
result.rightToLeftOffsetSec = rightCenter - leftCenter;
result.qualitySpreadSec = hypot(leftSpread, rightSpread);
result.note = "Right gateway time mapped into the left gateway clock.";

end

function delta = finiteArrivalMinusGateway(observation)

delta = zeros(0, 1);
if ~isstruct(observation) || ~isfield(observation, 'arrivalT') || ...
        ~isfield(observation, 'gatewayT')
    return;
end

arrivalT = double(observation.arrivalT(:));
gatewayT = double(observation.gatewayT(:));
n = min(numel(arrivalT), numel(gatewayT));
arrivalT = arrivalT(1:n);
gatewayT = gatewayT(1:n);
keep = isfinite(arrivalT) & isfinite(gatewayT);
delta = arrivalT(keep) - gatewayT(keep);

end

function value = robustSpread(x)

x = double(x(:));
center = median(x);
value = 1.4826 * median(abs(x - center));
if ~isfinite(value)
    value = NaN;
end

end

function result = baseResult()

result = struct( ...
    'success', false, ...
    'method', "passive", ...
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

function value = getNumericField(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName) && ...
        ~isempty(values.(fieldName)) && isfinite(double(values.(fieldName)(1)))
    value = double(values.(fieldName)(1));
else
    value = defaultValue;
end

end
