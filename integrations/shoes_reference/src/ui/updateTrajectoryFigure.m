function h = updateTrajectoryFigure(h, estimator, cfg)
% updateTrajectoryFigure  Update dual-foot trajectories and landing labels.

if nargin < 1 || isempty(h) || ~isfield(h, 'fig') || ~isvalid(h.fig)
    if nargin < 3
        cfg = struct();
    end
    h = initTrajectoryFigure(cfg);
end

if nargin < 2 || isempty(estimator)
    return;
end

h = applyCompletedSwingCorrection(h, estimator, 'left');
h = applyCompletedSwingCorrection(h, estimator, 'right');

leftPos = getEstimatorPosition(estimator, 'left');
rightPos = getEstimatorPosition(estimator, 'right');
sampleT = getEstimatorTime(estimator);

h.left(end + 1, :) = leftPos;
h.right(end + 1, :) = rightPos;
h.t(end + 1) = sampleT;

if numel(h.t) > h.maxPoints
    keep = numel(h.t) - h.maxPoints + 1:numel(h.t);
    h.left = h.left(keep, :);
    h.right = h.right(keep, :);
    h.t = h.t(keep);
end

h = recordLandingIfNeeded(h, estimator, 'left');
h = recordLandingIfNeeded(h, estimator, 'right');

setTrajectoryData(h.leftTrace, h.left);
setTrajectoryData(h.rightTrace, h.right);
setPointData(h.leftPoint, leftPos);
setPointData(h.rightPoint, rightPos);
updateZuptMarker(h.leftZupt, leftPos, getEstimatorZupt(estimator, 'left'));
updateZuptMarker(h.rightZupt, rightPos, getEstimatorZupt(estimator, 'right'));
updatePositionPlots(h);
updateMovingAxis(h, leftPos, rightPos);

end

function h = applyCompletedSwingCorrection(h, estimator, side)

if ~isfield(estimator, side)
    return;
end

foot = estimator.(side);
stepCount = getFootStepCount(foot);
lastField = getSideField('last', side, 'StepCount');
if ~isfield(h, lastField) || stepCount <= h.(lastField)
    return;
end

if isempty(h.t) || ~isfield(foot, 'lastCorrectedSwingT') || ...
        ~isfield(foot, 'lastCorrectedSwingPos')
    return;
end

tCorrected = double(foot.lastCorrectedSwingT(:));
posCorrected = double(foot.lastCorrectedSwingPos);
if numel(tCorrected) < 2 || size(posCorrected, 1) ~= numel(tCorrected)
    return;
end

[tCorrected, uniqueIndex] = unique(tCorrected, 'stable');
posCorrected = posCorrected(uniqueIndex, :);
historyMask = h.t >= tCorrected(1) & h.t <= tCorrected(end);
if any(historyMask)
    h.(side)(historyMask, :) = interp1(tCorrected, posCorrected, ...
        h.t(historyMask), 'linear');
end

end

function h = recordLandingIfNeeded(h, estimator, side)

if ~isfield(estimator, side)
    return;
end

foot = estimator.(side);
stepCount = getFootStepCount(foot);
lastField = getSideField('last', side, 'StepCount');
if stepCount <= h.(lastField)
    return;
end
h.(lastField) = stepCount;

landingPos = getFootLandingPosition(foot);
if ~all(isfinite(landingPos))
    return;
end

positionField = [side 'LandingPos'];
markerField = [side 'LandingMarkers'];
textField = [side 'LandingText'];
h.(positionField)(end + 1, :) = landingPos;
setTrajectoryData(h.(markerField), h.(positionField));

labelOffset = getLandingLabelOffset(h);
axisField = [side 'Ax'];
h.(textField)(end + 1, 1) = text(h.(axisField), ...
    landingPos(1), landingPos(2), landingPos(3) + labelOffset, ...
    sprintf('%d', stepCount), ...
    'Color', h.colors.(side), ...
    'FontWeight', 'bold', ...
    'FontSize', 9, ...
    'HorizontalAlignment', 'left', ...
    'VerticalAlignment', 'bottom', ...
    'Clipping', 'on', ...
    'HandleVisibility', 'off');

end

function updatePositionPlots(h)

if isempty(h.t) || isempty(h.left) || isempty(h.right)
    return;
end

tt = h.t - h.t(1);
setLineData(h.leftPosXLine, tt, h.left(:,1));
setLineData(h.rightPosXLine, tt, h.right(:,1));
setLineData(h.leftPosYLine, tt, h.left(:,2));
setLineData(h.rightPosYLine, tt, h.right(:,2));
setLineData(h.leftPosZLine, tt, h.left(:,3));
setLineData(h.rightPosZLine, tt, h.right(:,3));

xEnd = max(5, tt(end));
xStart = max(0, xEnd - 10);
set([h.axPosX h.axPosY h.axPosZ], 'XLim', [xStart xEnd]);

end

function updateMovingAxis(h, leftPos, rightPos)

if ~isfield(h, 'cfg') || ~isfield(h.cfg, 'axisLimit')
    return;
end

axisLimit = h.cfg.axisLimit;
center = 0.5 * (leftPos + rightPos);
updateFootAxis(h.leftAx, center, axisLimit);
updateFootAxis(h.rightAx, center, axisLimit);

end

function updateFootAxis(ax, center, axisLimit)

xHalf = 0.5 * (axisLimit(2) - axisLimit(1));
yHalf = 0.5 * (axisLimit(4) - axisLimit(3));

xlim(ax, center(1) + [-xHalf xHalf]);
ylim(ax, center(2) + [-yHalf yHalf]);
zlim(ax, axisLimit(5:6));

end

function setTrajectoryData(lineHandle, positions)

if isempty(positions)
    x = nan;
    y = nan;
    z = nan;
else
    if ~isnumeric(positions) || ~ismatrix(positions) || size(positions, 2) < 3
        error('gait:InvalidTrajectoryPlotData', ...
            'Trajectory plot data must be a numeric N-by-3 array.');
    end
    x = reshape(double(positions(:,1)), 1, []);
    y = reshape(double(positions(:,2)), 1, []);
    z = reshape(double(positions(:,3)), 1, []);
end

set(lineHandle, ...
    'XData', x, ...
    'YData', y, ...
    'ZData', z);

end

function setLineData(lineHandle, x, y)

x = reshape(double(x), 1, []);
y = reshape(double(y), 1, []);
if numel(x) ~= numel(y)
    error('gait:InvalidPositionPlotData', ...
        'Position plot XData and YData must have equal lengths.');
end
set(lineHandle, 'XData', x, 'YData', y, 'ZData', []);

end

function setPointData(pointHandle, pos)

set(pointHandle, 'XData', pos(1), 'YData', pos(2), 'ZData', pos(3));

end

function pos = getEstimatorPosition(estimator, side)

pos = [0 0 0];
if isstruct(estimator) && isfield(estimator, side)
    foot = estimator.(side);
    if isfield(foot, 'displayPos')
        pos = double(foot.displayPos(:).');
    elseif isfield(foot, 'pos')
        pos = double(foot.pos(:).');
    end
end

if numel(pos) < 3
    pos = [pos zeros(1, 3 - numel(pos))];
else
    pos = pos(1:3);
end

end

function pos = getFootLandingPosition(foot)

pos = [NaN NaN NaN];
if isstruct(foot) && isfield(foot, 'lastLandingPos')
    pos = double(foot.lastLandingPos(:).');
end
if numel(pos) < 3
    pos = [pos nan(1, 3 - numel(pos))];
else
    pos = pos(1:3);
end

end

function count = getFootStepCount(foot)

count = 0;
if isstruct(foot) && isfield(foot, 'stepCount') && ...
        isscalar(foot.stepCount) && isfinite(foot.stepCount)
    count = double(foot.stepCount);
end

end

function tf = getEstimatorZupt(estimator, side)

tf = false;
if isstruct(estimator) && isfield(estimator, side) && ...
        isfield(estimator.(side), 'zuptActive')
    tf = logical(estimator.(side).zuptActive);
end

end

function t = getEstimatorTime(estimator)

t = NaN;
if isstruct(estimator) && isfield(estimator, 'lastUpdateT')
    t = double(estimator.lastUpdateT);
end

if ~isfinite(t)
    t = posixtime(datetime("now"));
end

end

function updateZuptMarker(marker, pos, isZupt)

if isZupt
    setPointData(marker, pos);
    set(marker, 'Visible', 'on');
else
    set(marker, 'Visible', 'off');
end

end

function fieldName = getSideField(prefix, side, suffix)

fieldName = [prefix upper(side(1)) side(2:end) suffix];

end

function offset = getLandingLabelOffset(h)

offset = 0.02;
if isfield(h, 'cfg') && isfield(h.cfg, 'axisLimit')
    zRange = h.cfg.axisLimit(6) - h.cfg.axisLimit(5);
    if isfinite(zRange) && zRange > 0
        offset = max(0.01, 0.015 * zRange);
    end
end

end
