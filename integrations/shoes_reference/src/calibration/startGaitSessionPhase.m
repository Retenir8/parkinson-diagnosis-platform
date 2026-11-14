function [session, event] = startGaitSessionPhase(session, action, sensorT)
% startGaitSessionPhase  Apply a user-requested workflow transition.

if nargin < 1 || isempty(session)
    session = initGaitSessionState();
end
if nargin < 3
    sensorT = NaN;
end

action = string(action);
event = struct( ...
    'accepted', false, ...
    'resetRuntime', false, ...
    'stopRequested', false, ...
    'startTimeAlignment', false, ...
    'resetAlignmentRuntime', false, ...
    'message', "");

switch action
    case "start_unloaded"
        if session.phase == "recording"
            event.message = "Stop the active recording before recalibrating.";
            return;
        end
        oldRecordingIndex = session.recordingIndex;
        session = initGaitSessionState();
        session.recordingIndex = oldRecordingIndex;
        session.phase = "unloaded_calibration";
        session.statusMessage = "Empty-shoe calibration running. Do not touch either shoe.";
        event.accepted = true;
        event.message = session.statusMessage;

    case "start_worn"
        if ~session.unloadedComplete
            event.message = "Complete empty-shoe calibration first.";
            return;
        end
        session.worn.left = resetWornCollector(session.worn.left);
        session.worn.right = resetWornCollector(session.worn.right);
        session.wornComplete = false;
        session.phase = "worn_preparation";
        session.statusMessage = "Wear both shoes and stand still with both feet supported.";
        event.accepted = true;
        event.message = session.statusMessage;

    case "start_recording"
        if ~session.wornComplete
            event.message = "Complete worn standing preparation first.";
            return;
        end
        session.phase = "recording";
        session.recordingIndex = session.recordingIndex + 1;
        session.recordingStartT = sensorT;
        session.recordingStopT = NaN;
        session.statusMessage = "Analysis and formal recording are active.";
        event.accepted = true;
        event.resetRuntime = true;
        event.message = session.statusMessage;

    case "stop_recording"
        if session.phase ~= "recording"
            event.message = "No formal recording is currently active.";
            return;
        end
        session.phase = "finished";
        session.recordingStopT = sensorT;
        session.statusMessage = "Analysis and recording have ended.";
        event.accepted = true;
        event.stopRequested = true;
        event.message = session.statusMessage;

    case "shutdown"
        session.phase = "finished";
        session.recordingStopT = sensorT;
        session.statusMessage = "Program shutdown requested.";
        event.accepted = true;
        event.stopRequested = true;
        event.message = session.statusMessage;

    otherwise
        event.message = "Unknown session command.";
end

end

function collector = resetWornCollector(collector)

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
