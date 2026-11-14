function generateGaitVideoFromSession(sessionDir)
    if nargin < 1
        sessionDir = 'D:\Shoes\log\20260730_101441_345';   % 默认路径
    end
% 三个步态指标折线图横向排列，x轴刻度从0开始，强制为2的倍数
    if nargin < 1
        sessionDir = 'D:\Shoes\log\20260730_101441_345';
    end

    % 定位 step_metrics 文件
    files = dir(fullfile(sessionDir, 'step_metrics_*.csv'));
    if isempty(files)
        error('找不到 step_metrics_*.csv 文件');
    end
    stepFile = fullfile(sessionDir, files(1).name);

    % 读取数据
    stepTable = readtable(stepFile);
    foot = string(stepTable.foot);
    leftIdx  = foot == "left"; rightIdx = foot == "right";

    leftTimes_abs  = stepTable.land_time(leftIdx);   % 原始时间戳
    leftLength = stepTable.step_length_m(leftIdx);
    leftFreq   = stepTable.step_frequency_spm(leftIdx);
    leftSpeed  = stepTable.step_speed_mps(leftIdx);

    rightTimes_abs = stepTable.land_time(rightIdx);
    rightLength = stepTable.step_length_m(rightIdx);
    rightFreq   = stepTable.step_frequency_spm(rightIdx);
    rightSpeed  = stepTable.step_speed_mps(rightIdx);

    % 转换为相对时间（从第一个事件开始计时）
    tRef = min(min(leftTimes_abs), min(rightTimes_abs));  % 起始参考
    leftTimes  = leftTimes_abs - tRef;
    rightTimes = rightTimes_abs - tRef;

    % 列向量
    leftTimes  = leftTimes(:);  rightTimes = rightTimes(:);
    leftLength = leftLength(:); rightLength = rightLength(:);
    leftFreq   = leftFreq(:);   rightFreq   = rightFreq(:);
    leftSpeed  = leftSpeed(:);  rightSpeed  = rightSpeed(:);

    % 时间范围
    tAll = [leftTimes; rightTimes];
    tMin = min(tAll); tMax = max(tAll);
    if tMax - tMin < 1e-6, error('时间跨度过小'); end

    % 预设 x 轴刻度（从0开始的偶数整数）
    xTicks = 0:2:ceil(tMax);   % 0,2,4,... 直到覆盖 tMax
    if isempty(xTicks), xTicks = [0, ceil(tMax)]; end

    % 视频参数
    fps = 30;
    nFrames = round((tMax - tMin) * fps) + 1;
    tFrames = linspace(tMin, tMax, nFrames);   % 相对时间

    videoFile = fullfile(sessionDir, 'gait_analysis.mp4');
    if exist(videoFile, 'file'), delete(videoFile); end
    writer = VideoWriter(videoFile, 'MPEG-4');
    writer.FrameRate = fps;
    open(writer);

    % 图形布局（间距加大）
    fig = figure('Name','Gait Metrics','Position',[100 300 1200 350],'Color','w');
    ax1 = axes('Parent', fig, 'Position', [0.07 0.15 0.22 0.70]);
    ax2 = axes('Parent', fig, 'Position', [0.41 0.15 0.22 0.70]);
    ax3 = axes('Parent', fig, 'Position', [0.75 0.15 0.22 0.70]);

    hold(ax1,'on'); grid(ax1,'on'); xlabel(ax1,'Time (s)'); ylabel(ax1,'Step Length (m)'); title(ax1,'Step Length');
    hold(ax2,'on'); grid(ax2,'on'); xlabel(ax2,'Time (s)'); ylabel(ax2,'Step Frequency (spm)'); title(ax2,'Step Frequency');
    hold(ax3,'on'); grid(ax3,'on'); xlabel(ax3,'Time (s)'); ylabel(ax3,'Step Speed (m/s)'); title(ax3,'Step Speed');

    hLL = plot(ax1, NaN,NaN,'r-o','MarkerSize',4,'LineWidth',1.2);
    hRL = plot(ax1, NaN,NaN,'b-o','MarkerSize',4,'LineWidth',1.2);
    hLF = plot(ax2, NaN,NaN,'r-o','MarkerSize',4,'LineWidth',1.2);
    hRF = plot(ax2, NaN,NaN,'b-o','MarkerSize',4,'LineWidth',1.2);
    hLS = plot(ax3, NaN,NaN,'r-o','MarkerSize',4,'LineWidth',1.2);
    hRS = plot(ax3, NaN,NaN,'b-o','MarkerSize',4,'LineWidth',1.2);

    legend(ax1,[hLL,hRL],{'Left','Right'},'Location','best');
    legend(ax2,[hLF,hRF],{'Left','Right'},'Location','best');
    legend(ax3,[hLS,hRS],{'Left','Right'},'Location','best');

    tLine1 = xline(ax1,tMin,'k--'); tLine2 = xline(ax2,tMin,'k--'); tLine3 = xline(ax3,tMin,'k--');

    % 设置坐标轴范围（使用相对时间）
    setAxesLimits(ax1, leftTimes, rightTimes, leftLength, rightLength);
    setAxesLimits(ax2, leftTimes, rightTimes, leftFreq,   rightFreq);
    setAxesLimits(ax3, leftTimes, rightTimes, leftSpeed,  rightSpeed);

    % 强制固定 x 轴刻度为偶数整数（0,2,4,...）
    for ax = [ax1, ax2, ax3]
        set(ax, 'XTick', xTicks, 'XTickMode', 'manual');
    end

    % 逐帧绘制
    idxL=0; idxR=0;
    for k = 1:nFrames
        tNow = tFrames(k);   % 相对时间
        while idxL < length(leftTimes) && leftTimes(idxL+1) <= tNow, idxL=idxL+1; end
        while idxR < length(rightTimes) && rightTimes(idxR+1) <= tNow, idxR=idxR+1; end
        if idxL > 0
            set(hLL,'XData',leftTimes(1:idxL),'YData',leftLength(1:idxL));
            set(hLF,'XData',leftTimes(1:idxL),'YData',leftFreq(1:idxL));
            set(hLS,'XData',leftTimes(1:idxL),'YData',leftSpeed(1:idxL));
        end
        if idxR > 0
            set(hRL,'XData',rightTimes(1:idxR),'YData',rightLength(1:idxR));
            set(hRF,'XData',rightTimes(1:idxR),'YData',rightFreq(1:idxR));
            set(hRS,'XData',rightTimes(1:idxR),'YData',rightSpeed(1:idxR));
        end
        set(tLine1,'Value',tNow); set(tLine2,'Value',tNow); set(tLine3,'Value',tNow);
        drawnow;
        writeVideo(writer, getframe(fig));
    end

    close(writer); close(fig);
    fprintf('视频已生成：%s\n', videoFile);
end

function setAxesLimits(ax, tL, tR, dL, dR)
    tAll = [tL; tR]; dAll = [dL; dR];
    tAll = tAll(isfinite(tAll)); dAll = dAll(isfinite(dAll));
    if isempty(tAll), xlim(ax,[0 1]); ylim(ax,[0 1]); return; end
    tMn=min(tAll); tMx=max(tAll); yMn=min(dAll); yMx=max(dAll);
    if tMx-tMn<1e-6, tMx=tMn+1; end
    if yMx-yMn<1e-6, yMx=yMn+1; end
    dt = 0.05*(tMx-tMn); dy = 0.05*(yMx-yMn);
    xlim(ax, [tMn-dt, tMx+dt]);
    ylim(ax, [yMn-dy, yMx+dy]);
end