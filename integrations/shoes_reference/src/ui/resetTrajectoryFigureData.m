function h = resetTrajectoryFigureData(h, cfg)
% resetTrajectoryFigureData  Clear a trajectory figure without recreating it.

if nargin < 2
    cfg = struct();
end
if nargin < 1 || isempty(h) || ~isfield(h, 'fig') || ~isvalid(h.fig)
    h = initTrajectoryFigure(cfg);
    return;
end

deleteValidGraphics(getFieldOr(h, 'leftLandingText', gobjects(0, 1)));
deleteValidGraphics(getFieldOr(h, 'rightLandingText', gobjects(0, 1)));

h.left = zeros(0, 3);
h.right = zeros(0, 3);
h.t = [];
h.leftLandingPos = zeros(0, 3);
h.rightLandingPos = zeros(0, 3);
h.leftLandingText = gobjects(0, 1);
h.rightLandingText = gobjects(0, 1);
h.lastLeftStepCount = 0;
h.lastRightStepCount = 0;

clearTrajectoryLine(h.leftTrace);
clearTrajectoryLine(h.rightTrace);
clearTrajectoryLine(h.leftLandingMarkers);
clearTrajectoryLine(h.rightLandingMarkers);
clearTrajectoryLine(h.leftPoint);
clearTrajectoryLine(h.rightPoint);
clearTrajectoryLine(h.leftZupt);
clearTrajectoryLine(h.rightZupt);
clearPositionLine(h.leftPosXLine);
clearPositionLine(h.rightPosXLine);
clearPositionLine(h.leftPosYLine);
clearPositionLine(h.rightPosYLine);
clearPositionLine(h.leftPosZLine);
clearPositionLine(h.rightPosZLine);

if isfield(h, 'cfg') && isfield(h.cfg, 'axisLimit')
    axisLimit = h.cfg.axisLimit;
elseif isfield(cfg, 'axisLimit')
    axisLimit = cfg.axisLimit;
else
    axisLimit = [-2 2 -2 2 -0.5 1.5];
end
trajectoryAxes = getTrajectoryAxes(h);
for k = 1:numel(trajectoryAxes)
    xlim(trajectoryAxes(k), axisLimit(1:2));
    ylim(trajectoryAxes(k), axisLimit(3:4));
    zlim(trajectoryAxes(k), axisLimit(5:6));
end
set([h.axPosX h.axPosY h.axPosZ], 'XLim', [0 5]);

end

function axesHandles = getTrajectoryAxes(h)

if isfield(h, 'leftAx') && isfield(h, 'rightAx')
    axesHandles = [h.leftAx h.rightAx];
else
    axesHandles = h.ax;
end

axesHandles = axesHandles(isgraphics(axesHandles, 'axes'));

end

function clearTrajectoryLine(lineHandle)

if ~isempty(lineHandle) && isvalid(lineHandle)
    set(lineHandle, 'XData', nan, 'YData', nan, 'ZData', nan);
end

end

function clearPositionLine(lineHandle)

if ~isempty(lineHandle) && isvalid(lineHandle)
    set(lineHandle, 'XData', nan, 'YData', nan, 'ZData', []);
end

end

function deleteValidGraphics(handles)

handles = handles(isgraphics(handles));
if ~isempty(handles)
    delete(handles);
end

end

function value = getFieldOr(values, fieldName, defaultValue)

if isstruct(values) && isfield(values, fieldName)
    value = values.(fieldName);
else
    value = defaultValue;
end

end
