function generateGaitVideoFromSession(sessionDir)
    if nargin < 1
        sessionDir = 'D:\Shoes\log\20260730_101441_345';   % 默认路径
    end
% GENERATEGAITVIDEOFROMSESSION 从实时采集的会话数据生成步态分析视频
%   generateGaitVideoFromSession('D:\Shoes\log\20260730_101441_345')
%
%   视频内容（左侧三张2D折线图，右侧两张3D轨迹图）：
%     左侧纵列：Step Length / Step Frequency / Step Speed vs Time
%     右侧上：Left Foot 3D Trajectory
%     右侧下：Right Foot 3D Trajectory
%     轨迹图每步落点用圆点标记

    if nargin < 1
        sessionDir = 'D:\Shoes\log\20260730_101441_345';
    end

    % ---------- 自动查找数据文件 ----------
    files = dir(fullfile(sessionDir, '*.csv'));
    stepFile = '';
    trajFile = '';
    for i = 1:length(files)
        name = files(i).name;
        if startsWith(name, 'step_metrics_') && endsWith(name, '.csv')
            stepFile = fullfile(sessionDir, name);
        elseif startsWith(name, 'trajectory_state_') && endsWith(name, '.csv')
            trajFile = fullfile(sessionDir, name);
        end
    end

    if isempty(stepFile)
        error('在文件夹 %s 中未找到 step_metrics_*.csv 文件', sessionDir);
    end
    if isempty(trajFile)
        error('在文件夹 %s 中未找到 trajectory_state_*.csv 文件', sessionDir);
    end

    fprintf('读取步态指标文件: %s\n', stepFile);
    fprintf('读取轨迹状态文件: %s\n', trajFile);

    % ---------- 读取数据 ----------
    stepTable = readtable(stepFile);
    trajTable = readtable(trajFile);

    % 提取左右脚步数指标
    foot = string(stepTable.foot);
    leftIdx  = foot == "left";
    rightIdx = foot == "right";

    leftTimes  = stepTable.land_time(leftIdx);
    leftLength = stepTable.step_length_m(leftIdx);
    leftFreq   = stepTable.step_frequency_spm(leftIdx);
    leftSpeed  = stepTable.step_speed_mps(leftIdx);

    rightTimes  = stepTable.land_time(rightIdx);
    rightLength = stepTable.step_length_m(rightIdx);
    rightFreq   = stepTable.step_frequency_spm(rightIdx);
    rightSpeed  = stepTable.step_speed_mps(rightIdx);

    % 落点位置（用于轨迹标记）
    leftLandX = stepTable.landing_pos_x(leftIdx);
    leftLandY = stepTable.landing_pos_y(leftIdx);
    leftLandZ = stepTable.landing_pos_z(leftIdx);
    rightLandX = stepTable.landing_pos_x(rightIdx);
    rightLandY = stepTable.landing_pos_y(rightIdx);
    rightLandZ = stepTable.landing_pos_z(rightIdx);

    % 提取轨迹数据（已是原始程序去漂移后的 displayPos）
    trajTime = trajTable.t;
    leftX = trajTable.left_pos_x;
    leftY = trajTable.left_pos_y;
    leftZ = trajTable.left_pos_z;
    rightX = trajTable.right_pos_x;
    rightY = trajTable.right_pos_y;
    rightZ = trajTable.right_pos_z;

    % 确定全局时间范围
    allTimes = [trajTime; leftTimes; rightTimes];
    tMin = min(allTimes);
    tMax = max(allTimes);
    if tMax - tMin < 1e-6
        error('数据时间跨度太小，无法生成视频');
    end

    % ---------- 视频参数 ----------
    fps = 30;
    nFrames = round((tMax - tMin) * fps) + 1;
    tFrames = linspace(tMin, tMax, nFrames);

    % ---------- 创建视频文件 ----------
    videoFile = fullfile(sessionDir, 'gait_analysis.mp4');
    writer = VideoWriter(videoFile, 'MPEG-4');
    writer.FrameRate = fps;
    open(writer);

    % ---------- 初始化图形窗口（增高窗口，避免重叠） ----------
    fig = figure('Name', 'Gait Analysis Video', ...
                 'Position', [100 100 1200 900], ...
                 'Color', 'w');

    % 左侧三张折线图：垂直间距加大
    leftXPos = 0.07;
    leftWidth = 0.32;
    % 从上到下：y 起点分别为 0.70, 0.40, 0.10，高度 0.22
    ax1 = axes('Parent', fig, 'Position', [leftXPos, 0.70, leftWidth, 0.22]); % 步长
    ax2 = axes('Parent', fig, 'Position', [leftXPos, 0.40, leftWidth, 0.22]); % 步频
    ax3 = axes('Parent', fig, 'Position', [leftXPos, 0.10, leftWidth, 0.22]); % 步速

    % 右侧轨迹图：上下分布，留出间距
    ax4 = axes('Parent', fig, 'Position', [0.45, 0.52, 0.50, 0.36]); % 左脚轨迹
    ax5 = axes('Parent', fig, 'Position', [0.45, 0.08, 0.50, 0.36]); % 右脚轨迹

    % ---- 设置左侧折线图 ----
    hold(ax1, 'on'); grid(ax1, 'on');
    xlabel(ax1, 'Time (s)'); ylabel(ax1, 'Step Length (m)');
    title(ax1, 'Step Length');
    hold(ax2, 'on'); grid(ax2, 'on');
    xlabel(ax2, 'Time (s)'); ylabel(ax2, 'Step Frequency (spm)');
    title(ax2, 'Step Frequency');
    hold(ax3, 'on'); grid(ax3, 'on');
    xlabel(ax3, 'Time (s)'); ylabel(ax3, 'Step Speed (m/s)');
    title(ax3, 'Step Speed');

    % 初始化线对象（左红右蓝）
    hLeftLen  = plot(ax1, NaN, NaN, 'r-o', 'MarkerSize', 4, 'LineWidth', 1.2);
    hLeftFreq = plot(ax2, NaN, NaN, 'r-o', 'MarkerSize', 4, 'LineWidth', 1.2);
    hLeftSpd  = plot(ax3, NaN, NaN, 'r-o', 'MarkerSize', 4, 'LineWidth', 1.2);
    hRightLen  = plot(ax1, NaN, NaN, 'b-o', 'MarkerSize', 4, 'LineWidth', 1.2);
    hRightFreq = plot(ax2, NaN, NaN, 'b-o', 'MarkerSize', 4, 'LineWidth', 1.2);
    hRightSpd  = plot(ax3, NaN, NaN, 'b-o', 'MarkerSize', 4, 'LineWidth', 1.2);

    legend(ax1, [hLeftLen, hRightLen], {'Left', 'Right'}, 'Location', 'best');
    legend(ax2, [hLeftFreq, hRightFreq], {'Left', 'Right'}, 'Location', 'best');
    legend(ax3, [hLeftSpd, hRightSpd], {'Left', 'Right'}, 'Location', 'best');

    % 时间指示线
    tLine1 = xline(ax1, tMin, 'k--', 'LineWidth', 1);
    tLine2 = xline(ax2, tMin, 'k--', 'LineWidth', 1);
    tLine3 = xline(ax3, tMin, 'k--', 'LineWidth', 1);

    % 固定坐标轴范围
    setAxesLimits(ax1, leftTimes, rightTimes, leftLength, rightLength);
    setAxesLimits(ax2, leftTimes, rightTimes, leftFreq, rightFreq);
    setAxesLimits(ax3, leftTimes, rightTimes, leftSpeed, rightSpeed);

    % ---- 设置右侧轨迹图 ----
    hold(ax4, 'on'); grid(ax4, 'on');
    xlabel(ax4, 'X (m)'); ylabel(ax4, 'Y (m)'); zlabel(ax4, 'Z (m)');
    title(ax4, 'Left Foot Trajectory');
    view(ax4, 3);
    hTrajLeft = animatedline(ax4, 'Color', 'r', 'LineWidth', 1.2);

    hold(ax5, 'on'); grid(ax5, 'on');
    xlabel(ax5, 'X (m)'); ylabel(ax5, 'Y (m)'); zlabel(ax5, 'Z (m)');
    title(ax5, 'Right Foot Trajectory');
    view(ax5, 3);
    hTrajRight = animatedline(ax5, 'Color', 'b', 'LineWidth', 1.2);

    % 落点标记
    hMarkLeft  = plot3(ax4, NaN, NaN, NaN, 'r.', 'MarkerSize', 12);
    hMarkRight = plot3(ax5, NaN, NaN, NaN, 'b.', 'MarkerSize', 12);

    % 轨迹轴范围（基于全部轨迹数据）
    allTraj = [leftX, leftY, leftZ; rightX, rightY, rightZ];
    xRange = [min(allTraj(:,1)), max(allTraj(:,1))] + [-0.1 0.1];
    yRange = [min(allTraj(:,2)), max(allTraj(:,2))] + [-0.1 0.1];
    zRange = [min(allTraj(:,3)), max(allTraj(:,3))] + [-0.1 0.1];
    xlim(ax4, xRange); ylim(ax4, yRange); zlim(ax4, zRange);
    xlim(ax5, xRange); ylim(ax5, yRange); zlim(ax5, zRange);

    % ---------- 生成视频帧 ----------
    idxLeft   = 0;
    idxRight  = 0;
    idxTraj   = 0;
    idxMarkL  = 0;
    idxMarkR  = 0;

    for k = 1:nFrames
        tNow = tFrames(k);

        % ---- 步数指标折线 ----
        while idxLeft < length(leftTimes) && leftTimes(idxLeft+1) <= tNow
            idxLeft = idxLeft + 1;
        end
        while idxRight < length(rightTimes) && rightTimes(idxRight+1) <= tNow
            idxRight = idxRight + 1;
        end

        if idxLeft > 0
            set(hLeftLen,  'XData', leftTimes(1:idxLeft),  'YData', leftLength(1:idxLeft));
            set(hLeftFreq, 'XData', leftTimes(1:idxLeft),  'YData', leftFreq(1:idxLeft));
            set(hLeftSpd,  'XData', leftTimes(1:idxLeft),  'YData', leftSpeed(1:idxLeft));
        end
        if idxRight > 0
            set(hRightLen,  'XData', rightTimes(1:idxRight),  'YData', rightLength(1:idxRight));
            set(hRightFreq, 'XData', rightTimes(1:idxRight),  'YData', rightFreq(1:idxRight));
            set(hRightSpd,  'XData', rightTimes(1:idxRight),  'YData', rightSpeed(1:idxRight));
        end

        set(tLine1, 'Value', tNow);
        set(tLine2, 'Value', tNow);
        set(tLine3, 'Value', tNow);

        % ---- 轨迹累积 ----
        while idxTraj < length(trajTime) && trajTime(idxTraj+1) <= tNow
            idxTraj = idxTraj + 1;
            addpoints(hTrajLeft,  leftX(idxTraj),  leftY(idxTraj),  leftZ(idxTraj));
            addpoints(hTrajRight, rightX(idxTraj), rightY(idxTraj), rightZ(idxTraj));
        end

        % ---- 落点标记 ----
        while idxMarkL < length(leftTimes) && leftTimes(idxMarkL+1) <= tNow
            idxMarkL = idxMarkL + 1;
            set(hMarkLeft, 'XData', leftLandX(1:idxMarkL), ...
                           'YData', leftLandY(1:idxMarkL), ...
                           'ZData', leftLandZ(1:idxMarkL));
        end
        while idxMarkR < length(rightTimes) && rightTimes(idxMarkR+1) <= tNow
            idxMarkR = idxMarkR + 1;
            set(hMarkRight, 'XData', rightLandX(1:idxMarkR), ...
                            'YData', rightLandY(1:idxMarkR), ...
                            'ZData', rightLandZ(1:idxMarkR));
        end

        drawnow;
        frame = getframe(fig);
        writeVideo(writer, frame);
    end

    % ---------- 清理 ----------
    close(writer);
    close(fig);
    fprintf('视频已生成：%s\n', videoFile);
end

% ----------------- 辅助函数 -----------------
function setAxesLimits(ax, leftTimes, rightTimes, leftData, rightData)
    tAll = [leftTimes; rightTimes];
    yAll = [leftData; rightData];
    tAll = tAll(isfinite(tAll));
    yAll = yAll(isfinite(yAll));

    if isempty(tAll) || isempty(yAll)
        xlim(ax, [0 1]); ylim(ax, [0 1]);
        return;
    end
    tMin = min(tAll); tMax = max(tAll);
    yMin = min(yAll); yMax = max(yAll);
    if tMax - tMin < 1e-6
        tMax = tMin + 1;
    end
    if yMax - yMin < 1e-6
        yMax = yMin + 1;
    end
    dt = 0.05 * (tMax - tMin);
    dy = 0.05 * (yMax - yMin);
    xlim(ax, [tMin - dt, tMax + dt]);
    ylim(ax, [yMin - dy, yMax + dy]);
end