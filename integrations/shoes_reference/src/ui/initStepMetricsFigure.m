function h = initStepMetricsFigure(cfg)
% initStepMetricsFigure  Create step length/cadence/speed figure.

if nargin < 1
    cfg = struct();
end

if ~isfield(cfg, 'maxPoints')
    cfg.maxPoints = 100;
end

h = struct();
h.cfg = cfg;
h.maxPoints = cfg.maxPoints;
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

h.fig = figure( ...
    'Name', 'Step Metrics', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'Position', [920 120 760 640]);

h.axLength = subplot(3, 1, 1, 'Parent', h.fig);
setupMetricAxis(h.axLength, 'Step Length', 'm');
h.leftLengthLine = plot(h.axLength, nan, nan, 'r-o', 'LineWidth', 1.0, 'MarkerSize', 4);
h.rightLengthLine = plot(h.axLength, nan, nan, 'b-o', 'LineWidth', 1.0, 'MarkerSize', 4);
legend(h.axLength, {'Left', 'Right'}, 'Location', 'northeast');

h.axCadence = subplot(3, 1, 2, 'Parent', h.fig);
setupMetricAxis(h.axCadence, 'Step Frequency', 'steps/min');
h.leftCadenceLine = plot(h.axCadence, nan, nan, 'r-o', 'LineWidth', 1.0, 'MarkerSize', 4);
h.rightCadenceLine = plot(h.axCadence, nan, nan, 'b-o', 'LineWidth', 1.0, 'MarkerSize', 4);

h.axSpeed = subplot(3, 1, 3, 'Parent', h.fig);
setupMetricAxis(h.axSpeed, 'Step Speed', 'm/s');
h.leftSpeedLine = plot(h.axSpeed, nan, nan, 'r-o', 'LineWidth', 1.0, 'MarkerSize', 4);
h.rightSpeedLine = plot(h.axSpeed, nan, nan, 'b-o', 'LineWidth', 1.0, 'MarkerSize', 4);
xlabel(h.axSpeed, 'Step count per foot');

end

function setupMetricAxis(ax, titleText, yText)

hold(ax, 'on');
grid(ax, 'on');
title(ax, titleText);
ylabel(ax, yText);

end
