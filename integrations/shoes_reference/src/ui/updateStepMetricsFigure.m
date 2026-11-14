function h = updateStepMetricsFigure(h, estimator, cfg)
% updateStepMetricsFigure  Append new left/right foot step metrics.

if nargin < 1 || isempty(h) || ~isfield(h, 'fig') || ~isvalid(h.fig)
    if nargin < 3
        cfg = struct();
    end
    h = initStepMetricsFigure(cfg);
end

if nargin < 2 || isempty(estimator)
    return;
end

[h, changed] = appendFootMetric(h, estimator, 'left');
[h, changedRight] = appendFootMetric(h, estimator, 'right');
changed = changed || changedRight;

if ~changed
    return;
end

h = trimMetricHistory(h);

set(h.leftLengthLine, 'XData', h.leftIndex, 'YData', h.leftLength);
set(h.rightLengthLine, 'XData', h.rightIndex, 'YData', h.rightLength);
set(h.leftCadenceLine, 'XData', h.leftIndex, 'YData', h.leftCadence);
set(h.rightCadenceLine, 'XData', h.rightIndex, 'YData', h.rightCadence);
set(h.leftSpeedLine, 'XData', h.leftIndex, 'YData', h.leftSpeed);
set(h.rightSpeedLine, 'XData', h.rightIndex, 'YData', h.rightSpeed);

updateMetricXLim(h);

end

function [h, changed] = appendFootMetric(h, estimator, side)

changed = false;
if ~isfield(estimator, side)
    return;
end

foot = estimator.(side);
if ~isfield(foot, 'stepCount')
    return;
end

if strcmp(side, 'left')
    if foot.stepCount <= h.lastLeftStepCount
        return;
    end
    h.lastLeftStepCount = foot.stepCount;
    h.leftIndex(end + 1) = foot.stepCount;
    h.leftLength(end + 1) = getMetricValue(foot, 'stepLength');
    h.leftCadence(end + 1) = getMetricValue(foot, 'stepCadence');
    h.leftSpeed(end + 1) = getMetricValue(foot, 'stepSpeed');
else
    if foot.stepCount <= h.lastRightStepCount
        return;
    end
    h.lastRightStepCount = foot.stepCount;
    h.rightIndex(end + 1) = foot.stepCount;
    h.rightLength(end + 1) = getMetricValue(foot, 'stepLength');
    h.rightCadence(end + 1) = getMetricValue(foot, 'stepCadence');
    h.rightSpeed(end + 1) = getMetricValue(foot, 'stepSpeed');
end

changed = true;

end

function v = getMetricValue(foot, fieldName)

if isfield(foot, fieldName) && ~isempty(foot.(fieldName))
    v = double(foot.(fieldName));
else
    v = NaN;
end

end

function h = trimMetricHistory(h)

h.leftIndex = trimVector(h.leftIndex, h.maxPoints);
h.rightIndex = trimVector(h.rightIndex, h.maxPoints);
h.leftLength = trimVector(h.leftLength, h.maxPoints);
h.rightLength = trimVector(h.rightLength, h.maxPoints);
h.leftCadence = trimVector(h.leftCadence, h.maxPoints);
h.rightCadence = trimVector(h.rightCadence, h.maxPoints);
h.leftSpeed = trimVector(h.leftSpeed, h.maxPoints);
h.rightSpeed = trimVector(h.rightSpeed, h.maxPoints);

end

function v = trimVector(v, maxPoints)

if numel(v) > maxPoints
    v = v(end - maxPoints + 1:end);
end

end

function updateMetricXLim(h)

idx = [h.leftIndex h.rightIndex];
idx = idx(isfinite(idx));
if isempty(idx)
    return;
end

xEnd = max(10, max(idx));
xStart = max(0, xEnd - max(10, h.maxPoints));
set([h.axLength h.axCadence h.axSpeed], 'XLim', [xStart xEnd + 1]);

end
