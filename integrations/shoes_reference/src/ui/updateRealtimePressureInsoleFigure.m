%% =========================
% 单独绘制左右鞋垫压力热图
% ==========================


function h = updateRealtimePressureInsoleFigure(h, sample, cfgGait)

if nargin < 1 || isempty(h)
    h = [];
end

if nargin < 3
    cfgGait = struct();
end

leftValues = getPressureValues(sample, "left");
rightValues = getPressureValues(sample, "right");

if isempty(leftValues) || isempty(rightValues)
    return;
end

leftValues = leftValues(:);
rightValues = rightValues(:);

if numel(leftValues) < 48 || numel(rightValues) < 48
    return;
end

leftValues = leftValues(1:48);
rightValues = rightValues(1:48);

if isempty(h) || ~isstruct(h) || ~isfield(h, 'fig') || ~isvalid(h.fig)
    h = initPressureInsoleFigure(cfgGait);
end

maxPressure = max([leftValues; rightValues]);
if ~isfinite(maxPressure) || maxPressure <= 0
    maxPressure = 1;
end

% Smooth the color range a little so the heatmap does not flicker too much.
if ~isfield(h, 'colorMax') || isempty(h.colorMax) || ~isfinite(h.colorMax)
    h.colorMax = maxPressure;
else
    h.colorMax = 0.9 * h.colorMax + 0.1 * maxPressure;
end

h.colorMax = max(h.colorMax, 1);

updateOneFoot(h.left, leftValues, h.leftMap, h.colorMax);
updateOneFoot(h.right, rightValues, h.rightMap, h.colorMax);

if isfield(h, 'timeText') && isvalid(h.timeText)
    h.timeText.String = sprintf('Updated: %.3f', getSampleTime(sample));
end

% drawnow limitrate; % 删掉函数内部的 drawnow，统一在主循环里控制刷新

end

function h = initPressureInsoleFigure(cfgGait)

fig = figure( ...
    'Name', 'Realtime Plantar Pressure Insoles', ...
    'NumberTitle', 'off', ...
    'Color', 'w');

tiledlayout(fig, 1, 2, ...
    'Padding', 'compact', ...
    'TileSpacing', 'compact');

leftAx = nexttile;
rightAx = nexttile;

leftMap = makeLeftFootMap();
rightMap = makeRightFootMap();

left = initOneFoot(leftAx, leftMap, 'Left Foot');
right = initOneFoot(rightAx, rightMap, 'Right Foot');

% 热图颜色设置
n = 256;
whiteToRed = [ ...
    ones(n, 1), ...
    linspace(1, 0, n)', ...
    linspace(1, 0, n)' ...
];

colormap(fig, whiteToRed);


cb = colorbar(rightAx);
cb.Label.String = 'Pressure';

timeText = annotation(fig, 'textbox', [0.40 0.01 0.20 0.04], ...
    'String', '', ...
    'EdgeColor', 'none', ...
    'HorizontalAlignment', 'center', ...
    'FontSize', 9);

h = struct();
h.fig = fig;
h.left = left;
h.right = right;
h.leftMap = leftMap;
h.rightMap = rightMap;
h.colorMax = [];
h.timeText = timeText;
h.cfgGait = cfgGait;

end

function foot = initOneFoot(ax, sensorMap, titleText)

cla(ax);
hold(ax, 'on');

axis(ax, 'equal');
axis(ax, 'off');

title(ax, titleText, 'FontWeight', 'bold');

xlim(ax, [-3.0 3.0]);
ylim(ax, [0.0 13.4]);

drawInsoleShape(ax);

nSensors = 48;
patches = gobjects(nSensors, 1);
labels = gobjects(nSensors, 1);

for sensorId = 1:nSensors
    [rowIdx, colIdx] = find(sensorMap == sensorId, 1);

    if isempty(rowIdx)
        continue;
    end

    [x, y] = sensorPosition(rowIdx, colIdx);

    halfW = 0.33;
    halfH = 0.30;

    px = x + [-halfW halfW halfW -halfW];
    py = y + [-halfH -halfH halfH halfH];

    patches(sensorId) = patch(ax, px, py, 0, ...
        'EdgeColor', [0.05 0.05 0.05], ...
        'LineWidth', 1.2, ...
        'FaceColor', [0.95 0.95 0.95]);

    labels(sensorId) = text(ax, x, y, num2str(sensorId), ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'FontSize', 8, ...
        'FontWeight', 'bold', ...
        'Color', [0.75 0.05 0.05]);
end

foot = struct();
foot.ax = ax;
foot.patches = patches;
foot.labels = labels;
foot.sensorMap = sensorMap;

end

function updateOneFoot(foot, values, sensorMap, colorMax)

axes(foot.ax);
caxis(foot.ax, [0 colorMax]);

% Apply each pressure value to the patch carrying the same physical sensor
% number.  The map controls only where that sensor is drawn.
sensorIds = sensorMap(:).';
sensorIds = sensorIds(isfinite(sensorIds) & sensorIds >= 1 & sensorIds <= 48);

for sensorId = sensorIds
    if sensorId > numel(values)
        continue;
    end

    v = values(sensorId);

    if ~isfinite(v)
        v = 0;
    end

    if isvalid(foot.patches(sensorId))
        foot.patches(sensorId).CData = v;
        foot.patches(sensorId).FaceColor = 'flat';
    end

    if isvalid(foot.labels(sensorId))
        if v > 0.65 * colorMax
            foot.labels(sensorId).Color = [1 1 1];
        else
            foot.labels(sensorId).Color = [0.75 0.05 0.05];
        end
    end
end

end

function drawInsoleShape(ax)

% A simple insole outline: heel narrow, forefoot wide, toe rounded.
y = linspace(0.4, 12.9, 160);

width = 0.95 ...
    + 1.05 * exp(-((y - 9.6) / 2.7).^2) ...
    + 0.25 * exp(-((y - 12.0) / 1.2).^2) ...
    - 0.15 * exp(-((y - 1.0) / 0.8).^2);

center = 0.15 * sin((y - 2.0) / 10.5 * pi);

leftX = center - width;
rightX = center + width;

xPoly = [leftX fliplr(rightX)];
yPoly = [y fliplr(y)];

patch(ax, xPoly, yPoly, [0.00 0.70 0.45], ...
    'FaceAlpha', 0.22, ...
    'EdgeColor', [0.00 0.40 0.25], ...
    'LineWidth', 1.5);

% Light center guide lines, just to make the shape read like an insole.
plot(ax, center, y, '-', ...
    'Color', [0.00 0.45 0.30 0.35], ...
    'LineWidth', 0.8);

for k = [-0.5 0.5]
    plot(ax, center + k * width * 0.55, y, '-', ...
        'Color', [0.00 0.45 0.30 0.18], ...
        'LineWidth', 0.6);
end

end

function sensorMap = makeLeftFootMap()
% Rows are heel -> toe.
% Display columns are lateral -> medial for the left foot image because the
% medial side of the left foot is on the right side of the plot.
sensorMap = fliplr(makePhysicalSensorMap());
end

function sensorMap = makeRightFootMap()
% Rows are heel -> toe.
% Display columns are medial -> lateral for the right foot image because the
% medial side of the right foot is on the left side of the plot.
sensorMap = makePhysicalSensorMap();
end

function sensorMap = makePhysicalSensorMap()
% Physical sensor layout, independent of left/right plotting orientation:
% columns are medial -> lateral and rows are heel -> toe.
%
% 37:48  = most medial, heel -> toe
% 25:36  = inner-medial, heel -> toe
% 13:24  = outer-lateral, heel -> toe
%  1:12  = most lateral, heel -> toe
sensorMap = zeros(12, 4);
sensorStartByColumn = [37 25 13 1];

for colIdx = 1:4
    firstSensorId = sensorStartByColumn(colIdx);
    sensorMap(:, colIdx) = firstSensorId:(firstSensorId + 11);
end
end

function [x, y] = sensorPosition(rowIdx, colIdx)

xBase = [-1.25 -0.42 0.42 1.25];
yBase = linspace(1.1, 12.2, 12);

x = xBase(colIdx);
y = yBase(rowIdx);

% Slightly shape the sensor columns so they follow the insole contour.
forefootAmount = exp(-((y - 9.7) / 2.8).^2);
toeAmount = exp(-((y - 12.0) / 1.0).^2);
heelAmount = exp(-((y - 1.1) / 0.9).^2);

x = x * (0.75 + 0.18 * forefootAmount + 0.08 * toeAmount - 0.08 * heelAmount);

% Small toe row stagger, closer to the reference photo.
if rowIdx == 12
    if colIdx == 1 || colIdx == 4
        y = y - 0.20;
    end
end

if rowIdx == 1
    if colIdx == 1 || colIdx == 4
        y = y - 0.10;
    end
end

end

function values = getPressureValues(sample, footName)

values = [];

if ~isfield(sample, footName)
    return;
end

foot = sample.(footName);

if isfield(foot, 'pressure')
    pressure = foot.pressure;
else
    return;
end

if isfield(pressure, 'data') && isfield(pressure.data, 'values')
    values = pressure.data.values;
elseif isfield(pressure, 'values')
    values = pressure.values;
end

end

function t = getSampleTime(sample)

t = NaN;

if isfield(sample, 'time')
    t = sample.time;
elseif isfield(sample, 'timestamp')
    t = sample.timestamp;
elseif isfield(sample, 't')
    t = sample.t;
end

if isempty(t) || ~isnumeric(t)
    t = NaN;
end

end
