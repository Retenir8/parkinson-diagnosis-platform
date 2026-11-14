function h = resetStepMetricsFigureData(h, cfg)
% resetStepMetricsFigureData  Clear step metrics without recreating axes.

if nargin < 2
    cfg = struct();
end
if nargin < 1 || isempty(h) || ~isfield(h, 'fig') || ~isvalid(h.fig)
    h = initStepMetricsFigure(cfg);
    return;
end

h.lastLeftStepCount = 0;
h.lastRightStepCount = 0;
h.leftIndex = [];
h.rightIndex = [];
h.leftLength = [];
h.rightLength = [];
h.leftCadence = [];
h.rightCadence = [];
h.leftSpeed = [];
h.rightSpeed = [];

lines = [ ...
    h.leftLengthLine h.rightLengthLine ...
    h.leftCadenceLine h.rightCadenceLine ...
    h.leftSpeedLine h.rightSpeedLine];
for lineHandle = lines
    if isvalid(lineHandle)
        set(lineHandle, 'XData', nan, 'YData', nan);
    end
end
set([h.axLength h.axCadence h.axSpeed], 'XLim', [0 10]);

end
