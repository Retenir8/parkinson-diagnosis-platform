function imuPlotState = updateRealtimeImuFigure(imuPlotState, sample)

if isempty(imuPlotState) || ~isfield(imuPlotState, 'fig') || ~isvalid(imuPlotState.fig)
    imuPlotState = initRealtimeImuFigure();
end

% ===== 时间 =====
if isfield(sample, 't') && ~isempty(sample.t)
    t = double(sample.t);
else
    if isempty(imuPlotState.t)
        t = 0;
    else
        t = imuPlotState.t(end) + 1;
    end
end

% ===== 取左右脚 IMU =====
leftImu = getNestedFieldOr(sample, {'left','imu','data'}, struct());
rightImu = getNestedFieldOr(sample, {'right','imu','data'}, struct());

la = getVec(leftImu, 'acc_g');
ra = getVec(rightImu, 'acc_g');

lg = getVec(leftImu, 'gyr_dps');
rg = getVec(rightImu, 'gyr_dps');


% ===== 缓存 =====
imuPlotState.t(end+1) = t;

imuPlotState.leftAcc(end+1, :) = la;
imuPlotState.rightAcc(end+1, :) = ra;
imuPlotState.leftGyro(end+1, :) = lg;
imuPlotState.rightGyro(end+1, :) = rg;

maxPoints = imuPlotState.maxPoints;
if numel(imuPlotState.t) > maxPoints
    idx = numel(imuPlotState.t)-maxPoints+1:numel(imuPlotState.t);
    imuPlotState.t = imuPlotState.t(idx);
    imuPlotState.leftAcc = imuPlotState.leftAcc(idx, :);
    imuPlotState.rightAcc = imuPlotState.rightAcc(idx, :);
    imuPlotState.leftGyro = imuPlotState.leftGyro(idx, :);
    imuPlotState.rightGyro = imuPlotState.rightGyro(idx, :);
end

% ===== 时间归一化 =====
tt = imuPlotState.t - imuPlotState.t(1);

% ===== 更新曲线 =====
set(imuPlotState.hLeftAccX,  'XData', tt, 'YData', imuPlotState.leftAcc(:,1));
set(imuPlotState.hLeftAccY,  'XData', tt, 'YData', imuPlotState.leftAcc(:,2));
set(imuPlotState.hLeftAccZ,  'XData', tt, 'YData', imuPlotState.leftAcc(:,3));

set(imuPlotState.hRightAccX, 'XData', tt, 'YData', imuPlotState.rightAcc(:,1));
set(imuPlotState.hRightAccY, 'XData', tt, 'YData', imuPlotState.rightAcc(:,2));
set(imuPlotState.hRightAccZ, 'XData', tt, 'YData', imuPlotState.rightAcc(:,3));

set(imuPlotState.hLeftGyroX,  'XData', tt, 'YData', imuPlotState.leftGyro(:,1));
set(imuPlotState.hLeftGyroY,  'XData', tt, 'YData', imuPlotState.leftGyro(:,2));
set(imuPlotState.hLeftGyroZ,  'XData', tt, 'YData', imuPlotState.leftGyro(:,3));

set(imuPlotState.hRightGyroX, 'XData', tt, 'YData', imuPlotState.rightGyro(:,1));
set(imuPlotState.hRightGyroY, 'XData', tt, 'YData', imuPlotState.rightGyro(:,2));
set(imuPlotState.hRightGyroZ, 'XData', tt, 'YData', imuPlotState.rightGyro(:,3));

% ===== 滑动窗口 =====
windowSec = imuPlotState.windowSec;
xEnd = max(windowSec, tt(end));
xStart = max(0, xEnd - windowSec);

xlim(imuPlotState.axLeftAcc,  [xStart xEnd]);
xlim(imuPlotState.axRightAcc, [xStart xEnd]);
xlim(imuPlotState.axLeftGyro, [xStart xEnd]);
xlim(imuPlotState.axRightGyro,[xStart xEnd]);

drawnow limitrate;

end

function imuPlotState = initRealtimeImuFigure()

imuPlotState = struct();
imuPlotState.maxPoints = 1000;
imuPlotState.windowSec = 10;

imuPlotState.t = [];
imuPlotState.leftAcc = zeros(0,3);
imuPlotState.rightAcc = zeros(0,3);
imuPlotState.leftGyro = zeros(0,3);
imuPlotState.rightGyro = zeros(0,3);

imuPlotState.fig = figure( ...
    'Name', 'Realtime IMU', ...
    'NumberTitle', 'off', ...
    'Color', 'w', ...
    'Position', [120 120 1200 800]);

% ===== Left Acc =====
imuPlotState.axLeftAcc = subplot(2,2,1, 'Parent', imuPlotState.fig);
hold(imuPlotState.axLeftAcc, 'on'); grid(imuPlotState.axLeftAcc, 'on');
title(imuPlotState.axLeftAcc, 'Left Acc');
ylabel(imuPlotState.axLeftAcc, 'g');
imuPlotState.hLeftAccX = plot(imuPlotState.axLeftAcc, NaN, NaN, 'r');
imuPlotState.hLeftAccY = plot(imuPlotState.axLeftAcc, NaN, NaN, 'g');
imuPlotState.hLeftAccZ = plot(imuPlotState.axLeftAcc, NaN, NaN, 'b');
legend(imuPlotState.axLeftAcc, {'ax','ay','az'});

% ===== Right Acc =====
imuPlotState.axRightAcc = subplot(2,2,2, 'Parent', imuPlotState.fig);
hold(imuPlotState.axRightAcc, 'on'); grid(imuPlotState.axRightAcc, 'on');
title(imuPlotState.axRightAcc, 'Right Acc');
ylabel(imuPlotState.axRightAcc, 'g');
imuPlotState.hRightAccX = plot(imuPlotState.axRightAcc, NaN, NaN, 'r');
imuPlotState.hRightAccY = plot(imuPlotState.axRightAcc, NaN, NaN, 'g');
imuPlotState.hRightAccZ = plot(imuPlotState.axRightAcc, NaN, NaN, 'b');
legend(imuPlotState.axRightAcc, {'ax','ay','az'});

% ===== Left Gyro =====
imuPlotState.axLeftGyro = subplot(2,2,3, 'Parent', imuPlotState.fig);
hold(imuPlotState.axLeftGyro, 'on'); grid(imuPlotState.axLeftGyro, 'on');
title(imuPlotState.axLeftGyro, 'Left Gyro');
ylabel(imuPlotState.axLeftGyro, 'deg/s');
xlabel(imuPlotState.axLeftGyro, 'Time / s');
imuPlotState.hLeftGyroX = plot(imuPlotState.axLeftGyro, NaN, NaN, 'r');
imuPlotState.hLeftGyroY = plot(imuPlotState.axLeftGyro, NaN, NaN, 'g');
imuPlotState.hLeftGyroZ = plot(imuPlotState.axLeftGyro, NaN, NaN, 'b');
legend(imuPlotState.axLeftGyro, {'gx','gy','gz'});

% ===== Right Gyro =====
imuPlotState.axRightGyro = subplot(2,2,4, 'Parent', imuPlotState.fig);
hold(imuPlotState.axRightGyro, 'on'); grid(imuPlotState.axRightGyro, 'on');
title(imuPlotState.axRightGyro, 'Right Gyro');
ylabel(imuPlotState.axRightGyro, 'deg/s');
xlabel(imuPlotState.axRightGyro, 'Time / s');
imuPlotState.hRightGyroX = plot(imuPlotState.axRightGyro, NaN, NaN, 'r');
imuPlotState.hRightGyroY = plot(imuPlotState.axRightGyro, NaN, NaN, 'g');
imuPlotState.hRightGyroZ = plot(imuPlotState.axRightGyro, NaN, NaN, 'b');
legend(imuPlotState.axRightGyro, {'gx','gy','gz'});

end

function v = getVec(s, name)

if isstruct(s) && isfield(s, name) && numel(s.(name)) >= 3
    v = double(s.(name)(1:3));
    v = v(:).';
else
    v = [NaN NaN NaN];
end

end

function v = getNestedFieldOr(s, path, defaultValue)

v = s;
for i = 1:numel(path)
    name = path{i};
    if isstruct(v) && isfield(v, name) && ~isempty(v.(name))
        v = v.(name);
    else
        v = defaultValue;
        return;
    end
end

end
