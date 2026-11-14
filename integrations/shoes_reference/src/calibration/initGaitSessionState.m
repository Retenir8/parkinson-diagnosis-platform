function session = initGaitSessionState()
% initGaitSessionState  Initialize the guided calibration/recording workflow.

session = struct();
session.phase = "waiting_unloaded";
session.statusMessage = ...
    "Place both empty shoes parallel on a rigid floor, then start calibration.";
session.unloaded.left = initUnloadedCollector();
session.unloaded.right = initUnloadedCollector();
session.worn.left = initWornCollector();
session.worn.right = initWornCollector();
session.calibration.left = struct();
session.calibration.right = struct();
session.unloadedComplete = false;
session.wornComplete = false;
session.recordingStartT = NaN;
session.recordingStopT = NaN;
session.recordingIndex = 0;

end

function collector = initUnloadedCollector()

collector = struct();
collector.complete = false;
collector.imuT = zeros(0, 1);
collector.accResidualBody = zeros(0, 3);
collector.qWxyz = zeros(0, 4);
collector.angularRateDeg = zeros(0, 1);
collector.pressureT = zeros(0, 1);
collector.pressure = zeros(0, 48);
collector.previousImuT = NaN;
collector.previousQ = [NaN NaN NaN NaN];
collector.lastIssue = "";
collector.result = struct();

end

function collector = initWornCollector()

collector = struct();
collector.complete = false;
collector.imuT = zeros(0, 1);
collector.qWxyz = zeros(0, 4);
collector.accWorldResidual = zeros(0, 3);
collector.angularRateDeg = zeros(0, 1);
collector.pressureT = zeros(0, 1);
collector.pressure = zeros(0, 48);
collector.totalPressure = zeros(0, 1);
collector.cop = zeros(0, 2);
collector.previousImuT = NaN;
collector.previousQ = [NaN NaN NaN NaN];
collector.lastPressureT = NaN;
collector.contactPresent = false;
collector.lastIssue = "";
collector.result = struct();

end
