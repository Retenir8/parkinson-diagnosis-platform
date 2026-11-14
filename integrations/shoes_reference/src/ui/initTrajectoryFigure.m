function h = initTrajectoryFigure(cfg)
% initTrajectoryFigure  Create a dual-foot 3D trajectory figure.

if nargin < 1
    cfg = struct();
end

if ~isfield(cfg, 'axisLimit')
    cfg.axisLimit = [-2 2 -2 2 -0.5 1.5];
end
if ~isfield(cfg, 'maxPoints')
    cfg.maxPoints = 1000;
end

leftColor = [0.82 0.18 0.20];
rightColor = [0.10 0.36 0.82];

h = struct();
h.cfg = cfg;
h.colors.left = leftColor;
h.colors.right = rightColor;
h.fig = figure( ...
    'Name', 'IMU + Pressure ZUPT Trajectory', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'Position', [80 80 1400 780]);

tl = tiledlayout(h.fig, 6, 9, ...
    'Padding', 'compact', ...
    'TileSpacing', 'compact');

h.leftAx = nexttile(tl, 1, [5 4]);
setupTrajectoryAxis(h.leftAx, 'Left Foot Trajectory', cfg.axisLimit);
h.rightAx = nexttile(tl, 6, [5 4]);
setupTrajectoryAxis(h.rightAx, 'Right Foot Trajectory', cfg.axisLimit);

% Keep the legacy field for callers that used the original shared axis.
h.ax = h.leftAx;

h.leftTrace = plot3(h.leftAx, nan, nan, nan, '-', ...
    'Color', leftColor, 'LineWidth', 1.4);
h.rightTrace = plot3(h.rightAx, nan, nan, nan, '-', ...
    'Color', rightColor, 'LineWidth', 1.4);
h.leftLandingMarkers = plot3(h.leftAx, nan, nan, nan, 'o', ...
    'LineStyle', 'none', 'Color', leftColor, ...
    'MarkerFaceColor', leftColor, 'MarkerSize', 6);
h.rightLandingMarkers = plot3(h.rightAx, nan, nan, nan, 'o', ...
    'LineStyle', 'none', 'Color', rightColor, ...
    'MarkerFaceColor', rightColor, 'MarkerSize', 6);
h.leftPoint = plot3(h.leftAx, nan, nan, nan, 'o', ...
    'Color', leftColor, 'MarkerFaceColor', 'w', 'MarkerSize', 8, ...
    'HandleVisibility', 'off');
h.rightPoint = plot3(h.rightAx, nan, nan, nan, 'o', ...
    'Color', rightColor, 'MarkerFaceColor', 'w', 'MarkerSize', 8, ...
    'HandleVisibility', 'off');
h.leftZupt = plot3(h.leftAx, nan, nan, nan, 's', ...
    'Color', leftColor, 'MarkerSize', 10, 'LineWidth', 1.2, ...
    'HandleVisibility', 'off');
h.rightZupt = plot3(h.rightAx, nan, nan, nan, 's', ...
    'Color', rightColor, 'MarkerSize', 10, 'LineWidth', 1.2, ...
    'HandleVisibility', 'off');

legend(h.leftAx, [h.leftTrace h.leftLandingMarkers], ...
    {'Left path', 'Landings'}, ...
    'Location', 'northeast');
legend(h.rightAx, [h.rightTrace h.rightLandingMarkers], ...
    {'Right path', 'Landings'}, ...
    'Location', 'northeast');

h.axPosX = nexttile(tl, 47, [1 2]);
setupPositionAxis(h.axPosX, 'Position X', 'X / m');
h.leftPosXLine = plot(h.axPosX, nan, nan, '-', ...
    'Color', leftColor, 'LineWidth', 1.1);
h.rightPosXLine = plot(h.axPosX, nan, nan, '-', ...
    'Color', rightColor, 'LineWidth', 1.1);
legend(h.axPosX, [h.leftPosXLine h.rightPosXLine], ...
    {'Left', 'Right'}, 'Location', 'best');

h.axPosY = nexttile(tl, 49, [1 2]);
setupPositionAxis(h.axPosY, 'Position Y', 'Y / m');
h.leftPosYLine = plot(h.axPosY, nan, nan, '-', ...
    'Color', leftColor, 'LineWidth', 1.1);
h.rightPosYLine = plot(h.axPosY, nan, nan, '-', ...
    'Color', rightColor, 'LineWidth', 1.1);

h.axPosZ = nexttile(tl, 51, [1 2]);
setupPositionAxis(h.axPosZ, 'Position Z', 'Z / m');
h.leftPosZLine = plot(h.axPosZ, nan, nan, '-', ...
    'Color', leftColor, 'LineWidth', 1.1);
h.rightPosZLine = plot(h.axPosZ, nan, nan, '-', ...
    'Color', rightColor, 'LineWidth', 1.1);

h.left = zeros(0, 3);
h.right = zeros(0, 3);
h.t = [];
h.maxPoints = cfg.maxPoints;
h.leftLandingPos = zeros(0, 3);
h.rightLandingPos = zeros(0, 3);
h.leftLandingText = gobjects(0, 1);
h.rightLandingText = gobjects(0, 1);
h.lastLeftStepCount = 0;
h.lastRightStepCount = 0;

end

function setupTrajectoryAxis(ax, titleText, axisLimit)

hold(ax, 'on');
grid(ax, 'on');
axis(ax, 'equal');
view(ax, 3);
xlabel(ax, 'X / m');
ylabel(ax, 'Y / m');
zlabel(ax, 'Z / m');
title(ax, titleText);
xlim(ax, axisLimit(1:2));
ylim(ax, axisLimit(3:4));
zlim(ax, axisLimit(5:6));

end

function setupPositionAxis(ax, titleText, yText)

hold(ax, 'on');
grid(ax, 'on');
title(ax, titleText);
ylabel(ax, yText);
xlabel(ax, 'Time / s');

end
