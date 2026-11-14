function report = analyzeGaitLowLatencyLog(fileName, cfg)
% analyzeGaitLowLatencyLog  Plot pressure/contact/event diagnostics from CSV.

setupGaitProject();
if nargin < 1 || isempty(fileName)
    fileName = 'gait_state.csv';
end
if nargin < 2
    cfg = struct();
end

cfg = fillDefaults(cfg);
T = readtable(fileName, 'VariableNamingRule', 'preserve');

report = struct();
report.fileName = fileName;

feet = ["left", "right"];
fig = figure('Name', 'Gait Pressure / ZUPT Diagnostics', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'Position', [80 80 1280 820]);
tl = tiledlayout(fig, 3, 2, 'Padding', 'compact', 'TileSpacing', 'compact');

for i = 1:numel(feet)
    foot = feet(i);
    idx = string(T.foot) == foot;
    if any(strcmp(T.Properties.VariableNames, 'sensor_type'))
        idx = idx & string(T.sensor_type) == "pressure";
    end
    F = T(idx, :);
    if isempty(F)
        warning('No pressure rows found for %s in %s.', foot, fileName);
        report.(foot).samples = 0;
        report.(foot).detectedLandingEvents = 0;
        report.(foot).detectedToeOffEvents = 0;
        report.(foot).totalPressureMin = NaN;
        report.(foot).totalPressureMedian = NaN;
        report.(foot).totalPressureMax = NaN;
        report.(foot).dtMedian = NaN;
        report.(foot).dtP95 = NaN;
        report.(foot).dtMax = NaN;
        continue;
    end
    t = F.t - F.t(1);
    total = F.total;
    loadIndex = F.loadIndex;
    contact = logical(F.contact);
    dt = [NaN; diff(F.t)];
    eventIdx = find([false; ~contact(1:end-1) & contact(2:end)]);
    offIdx = find([false; contact(1:end-1) & ~contact(2:end)]);

    report.(foot).samples = height(F);
    report.(foot).detectedLandingEvents = numel(eventIdx);
    report.(foot).detectedToeOffEvents = numel(offIdx);
    report.(foot).totalPressureMin = min(total);
    report.(foot).totalPressureMedian = median(total);
    report.(foot).totalPressureMax = max(total);
    report.(foot).dtMedian = median(dt, 'omitnan');
    report.(foot).dtP95 = prctile(dt, 95);
    report.(foot).dtMax = max(dt, [], 'omitnan');

    ax1 = nexttile(tl, i);
    hold(ax1, 'on'); grid(ax1, 'on');
    plot(ax1, t, total, 'k-', 'LineWidth', 1.0);
    yline(ax1, cfg.absolutePressureOnThreshold, 'r--', 'on abs');
    yline(ax1, cfg.absolutePressureOffThreshold, 'b--', 'off abs');
    scatter(ax1, t(eventIdx), total(eventIdx), 36, 'g', 'filled');
    scatter(ax1, t(offIdx), total(offIdx), 28, 'm', 'filled');
    title(ax1, sprintf('%s totalPressure / events', foot));
    xlabel(ax1, 'Time / s');
    ylabel(ax1, 'totalPressure');
    legend(ax1, {'total', 'on', 'off', 'landing', 'toe-off'}, 'Location', 'best');

    ax2 = nexttile(tl, i + 2);
    hold(ax2, 'on'); grid(ax2, 'on');
    plot(ax2, t, loadIndex, 'Color', [0.15 0.15 0.15], 'LineWidth', 1.0);
    stairs(ax2, t, double(contact), 'g-', 'LineWidth', 1.4);
    yline(ax2, cfg.loadOnThreshold, 'r--', 'on load');
    yline(ax2, cfg.loadOffThreshold, 'b--', 'off load');
    scatter(ax2, t(eventIdx), ones(size(eventIdx)), 36, 'g', 'filled');
    title(ax2, sprintf('%s loadIndex / stance', foot));
    xlabel(ax2, 'Time / s');
    ylabel(ax2, 'load / stance');
    legend(ax2, {'loadIndex', 'stance', 'on', 'off', 'landing'}, 'Location', 'best');

    ax3 = nexttile(tl, i + 4);
    hold(ax3, 'on'); grid(ax3, 'on');
    plot(ax3, t, dt, 'k-', 'LineWidth', 1.0);
    yline(ax3, cfg.maxDt, 'r--', 'maxDt');
    title(ax3, sprintf('%s pressure dt', foot));
    xlabel(ax3, 'Time / s');
    ylabel(ax3, 'dt / s');
end

fprintf('Diagnostics for %s\n', fileName);
for i = 1:numel(feet)
    foot = feet(i);
    r = report.(foot);
    fprintf('%s: samples=%d landing=%d toeOff=%d total[min/med/max]=%.1f/%.1f/%.1f dt[med/p95/max]=%.4f/%.4f/%.4f s\n', ...
        foot, r.samples, r.detectedLandingEvents, r.detectedToeOffEvents, ...
        r.totalPressureMin, r.totalPressureMedian, r.totalPressureMax, ...
        r.dtMedian, r.dtP95, r.dtMax);
end

end

function cfg = fillDefaults(cfg)

if ~isfield(cfg, 'loadOnThreshold')
    cfg.loadOnThreshold = 0.20;
end
if ~isfield(cfg, 'loadOffThreshold')
    cfg.loadOffThreshold = 0.10;
end
if ~isfield(cfg, 'absolutePressureOnThreshold')
    cfg.absolutePressureOnThreshold = 300;
end
if ~isfield(cfg, 'absolutePressureOffThreshold')
    cfg.absolutePressureOffThreshold = 150;
end
if ~isfield(cfg, 'maxDt')
    cfg.maxDt = 0.15;
end

end
