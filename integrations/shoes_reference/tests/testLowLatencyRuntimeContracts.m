function tests = testLowLatencyRuntimeContracts
% testLowLatencyRuntimeContracts  Regression tests for logging and UI shutdown.

tests = functiontests(localfunctions);

end

function testDecodedPressureRowHasStableColumns(testCase)

cfg = pressureRegionConfig();
msg = struct();
msg.recv_time_sec = 123.456;
msg.recv_time_str = "2026-07-28 07:00:01.234";
msg.aligned_time_sec = msg.recv_time_sec;
msg.aligned_time_str = msg.recv_time_str;
msg.gateway_time_sec = 123.333;
msg.gateway_time_str = "2026-07-28 07:00:00.123";
msg.arrival_time_sec = 123.777;
msg.arrival_time_str = "2026-07-28 07:00:01.555";
msg.time_alignment_method = "tap";
msg.time_alignment_ready = true;
msg.time_alignment_offset_sec = 0.123;
msg.foot = "left";
msg.data.values = 1:48;

row = formatDecodedPressureCsvRow(msg, "recording", 2.5, true, cfg, 20);
fields = split(string(row), ',');

verifyEqual(testCase, numel(fields), 72);
verifyEqual(testCase, str2double(fields(1)), msg.recv_time_sec);
verifyEqual(testCase, fields(2), msg.recv_time_str);
verifyEqual(testCase, str2double(fields(3)), msg.gateway_time_sec);
verifyEqual(testCase, fields(4), msg.gateway_time_str);
verifyEqual(testCase, str2double(fields(5)), msg.arrival_time_sec);
verifyEqual(testCase, fields(6), msg.arrival_time_str);
verifyEqual(testCase, fields(7), msg.time_alignment_method);
verifyEqual(testCase, str2double(fields(8)), 1);
verifyEqual(testCase, str2double(fields(9)), 123);
verifyEqual(testCase, str2double(fields(13)), 1);
verifyEqual(testCase, str2double(fields(14)), sum(1:48));
verifyEqual(testCase, str2double(fields(15)), 28);
verifyEqual(testCase, str2double(fields(16)), 48);
verifyEqual(testCase, str2double(fields(25:72)).', 1:48);

end

function testMqttArrivalTimestampUsesCallbackCapture(testCase)

rawMsg = struct( ...
    'ArrivalEpochSec', 1785238000.125, ...
    'ArrivalTimeStr', "2026-07-28 19:26:40.125");
[t, timeText] = getMqttArrivalTimestamp(rawMsg);

verifyEqual(testCase, t, 1785238000.125, 'AbsTol', 1e-12);
verifyEqual(testCase, timeText, "2026-07-28 19:26:40.125");

end

function testMqttDecoderUsesPayloadGatewayTimeAsSampleTime(testCase)

hex = [ ...
    '5A A5 24 00 7E 37 83 00 18 01 11 00 00 00 ' ...
    '07 1D AE 3C 58 C0 52 40 6A 79 13 41 BE 39 ' ...
    '7C 3F 04 2F 2F 3E C5 88 D7 BA 8F DE B1 B9'];
payload = ['[2026-07-28 15:33:24.059]' hex];
cfg.devices = struct( ...
    'id', {"AABBCCDDEEFF", "112233445566"}, ...
    'foot', {"left", "right"});
rawMsg.ArrivalEpochSec = 987654321.25;
rawMsg.ArrivalTimeStr = "callback arrival";

msg = decodeMqttSensorMessage( ...
    "D2S/U/1/AABBCCDDEEFF", payload, cfg, rawMsg);

verifyEqual(testCase, msg.recv_time_sec, msg.gateway_time_sec);
verifyEqual(testCase, msg.t, msg.gateway_time_sec);
verifyNotEqual(testCase, msg.recv_time_sec, msg.arrival_time_sec);
verifyEqual(testCase, msg.arrival_time_sec, rawMsg.ArrivalEpochSec);
verifyEqual(testCase, msg.recv_time_str, msg.gateway_time_str);

end

function testStaleFramesAreRejectedPerIndependentStream(testCase)

lastT = struct();
[lastT, accepted] = acceptSensorMessageTimestamp(lastT, sensorMsg("left", "imu", 10.0));
verifyTrue(testCase, accepted);
[lastT, accepted] = acceptSensorMessageTimestamp(lastT, sensorMsg("right", "imu", 9.0));
verifyTrue(testCase, accepted);
[lastT, accepted] = acceptSensorMessageTimestamp(lastT, sensorMsg("left", "pressure", 8.0));
verifyTrue(testCase, accepted);
[lastT, accepted] = acceptSensorMessageTimestamp(lastT, sensorMsg("left", "imu", 9.5));
verifyFalse(testCase, accepted);
[lastT, accepted] = acceptSensorMessageTimestamp(lastT, sensorMsg("left", "imu", 10.0));
verifyFalse(testCase, accepted);
[~, accepted] = acceptSensorMessageTimestamp(lastT, sensorMsg("left", "imu", 10.01));
verifyTrue(testCase, accepted);

end

function testCloseRequestsShutdownAndDeletesActiveWindow(testCase)

key = 'test_gait_shutdown_active';
cleanup = onCleanup(@() cleanupTestState(key)); %#ok<NASGU>
setappdata(0, key, '');
fig = figure('Visible', 'off');

requestGaitSessionShutdown(fig, key);

verifyFalse(testCase, isvalid(fig));
verifyEqual(testCase, string(getappdata(0, key)), "shutdown");

end

function testCloseAfterCleanupDoesNotRecreateCommandKey(testCase)

key = 'test_gait_shutdown_finished';
cleanup = onCleanup(@() cleanupTestState(key)); %#ok<NASGU>
if isappdata(0, key)
    rmappdata(0, key);
end
fig = figure('Visible', 'off');

requestGaitSessionShutdown(fig, key);

verifyFalse(testCase, isvalid(fig));
verifyFalse(testCase, isappdata(0, key));

end

function testTrajectoryFigureResetReusesExistingFigure(testCase)

oldVisibility = get(groot, 'DefaultFigureVisible');
set(groot, 'DefaultFigureVisible', 'off');
cleanup = onCleanup(@() restoreFigureVisibility(oldVisibility)); %#ok<NASGU>

cfg.axisLimit = [-2 2 -2 2 -0.5 1.5];
cfg.maxPoints = 100;
h = initTrajectoryFigure(cfg);
figureHandle = h.fig;
h.left = [1 2 3];
h.right = [4 5 6];
h.t = 10;
h.leftLandingText = text(h.ax, 1, 2, 3, '1');
set(h.leftTrace, 'XData', 1, 'YData', 2, 'ZData', 3);

h = resetTrajectoryFigureData(h, cfg);

verifyEqual(testCase, h.fig, figureHandle);
verifyTrue(testCase, isvalid(figureHandle));
verifyEmpty(testCase, h.t);
verifySize(testCase, h.left, [0 3]);
verifyEmpty(testCase, h.leftLandingText);
verifyTrue(testCase, all(isnan(get(h.leftTrace, 'XData'))));
close(figureHandle);

end

function testTrajectoryFigureUsesSeparateFootAxesAbovePositionPlots(testCase)

oldVisibility = get(groot, 'DefaultFigureVisible');
set(groot, 'DefaultFigureVisible', 'off');
cleanup = onCleanup(@() restoreFigureVisibility(oldVisibility)); %#ok<NASGU>

cfg.axisLimit = [-2 2 -2 2 -0.5 1.5];
cfg.maxPoints = 100;
h = initTrajectoryFigure(cfg);
figureCleanup = onCleanup(@() closeFigureIfValid(h.fig)); %#ok<NASGU>
drawnow;

verifyNotEqual(testCase, h.leftAx, h.rightAx);
verifyEqual(testCase, h.leftTrace.Parent, h.leftAx);
verifyEqual(testCase, h.leftLandingMarkers.Parent, h.leftAx);
verifyEqual(testCase, h.rightTrace.Parent, h.rightAx);
verifyEqual(testCase, h.rightLandingMarkers.Parent, h.rightAx);

leftRect = getpixelposition(h.leftAx, true);
rightRect = getpixelposition(h.rightAx, true);
xRect = getpixelposition(h.axPosX, true);
yRect = getpixelposition(h.axPosY, true);
zRect = getpixelposition(h.axPosZ, true);
verifyLessThan(testCase, leftRect(1), rightRect(1));
verifyGreaterThan(testCase, leftRect(2), xRect(2));
verifyLessThan(testCase, xRect(1), yRect(1));
verifyLessThan(testCase, yRect(1), zRect(1));
verifyLessThan(testCase, xRect(4), 0.30 * leftRect(4));
verifyLessThan(testCase, xRect(3), 0.65 * leftRect(3));

end

function testStepMetricsFigureResetReusesExistingFigure(testCase)

oldVisibility = get(groot, 'DefaultFigureVisible');
set(groot, 'DefaultFigureVisible', 'off');
cleanup = onCleanup(@() restoreFigureVisibility(oldVisibility)); %#ok<NASGU>

cfg.maxPoints = 20;
h = initStepMetricsFigure(cfg);
figureHandle = h.fig;
h.leftIndex = 1;
h.leftLength = 0.5;
set(h.leftLengthLine, 'XData', 1, 'YData', 0.5);

h = resetStepMetricsFigureData(h, cfg);

verifyEqual(testCase, h.fig, figureHandle);
verifyTrue(testCase, isvalid(figureHandle));
verifyEmpty(testCase, h.leftIndex);
verifyEmpty(testCase, h.leftLength);
verifyTrue(testCase, all(isnan(get(h.leftLengthLine, 'XData'))));
close(figureHandle);

end

function testGatewayIdsBuildTopicsAndFootMapping(testCase)

cfg = struct();
cfg.mqtt = struct();
cfg = configureGaitGatewayIds( ...
    cfg, "34:cd:b0:af:20:6c", "34-CD-B0-AF-22-8C");

verifyEqual(testCase, cfg.mqtt.gatewayIds.left, "AABBCCDDEEFF");
verifyEqual(testCase, cfg.mqtt.gatewayIds.right, "112233445566");
verifyEqual(testCase, cfg.mqtt.topics.leftImu, ...
    "D2S/U/1/AABBCCDDEEFF");
verifyEqual(testCase, cfg.mqtt.topics.rightImu, ...
    "D2S/U/1/112233445566");
verifyEqual(testCase, cfg.mqtt.topics.leftPressure, ...
    "D2S/U/0/AABBCCDDEEFF");
verifyEqual(testCase, cfg.mqtt.topics.rightPressure, ...
    "D2S/U/0/112233445566");
verifyEqual(testCase, string({cfg.devices.id}), ...
    ["AABBCCDDEEFF" "112233445566"]);
verifyEqual(testCase, string({cfg.devices.foot}), ["left" "right"]);

end

function testGatewayIdsRejectInvalidValue(testCase)

verifyError(testCase, ...
    @() configureGaitGatewayIds(struct(), "NOT_HEX", "112233445566"), ...
    'gait:InvalidGatewayId');

end

function testGatewayIdsRejectDuplicateFeet(testCase)

verifyError(testCase, ...
    @() configureGaitGatewayIds( ...
        struct(), "AABBCCDDEEFF", "AABBCCDDEEFF"), ...
    'gait:DuplicateGatewayId');

end

function testImuMqttStreamSkipsGatewayPrefix(testCase)

hex = [ ...
    '5A A5 24 00 7E 37 83 00 18 01 11 00 00 00 ' ...
    '07 1D AE 3C 58 C0 52 40 6A 79 13 41 BE 39 ' ...
    '7C 3F 04 2F 2F 3E C5 88 D7 BA 8F DE B1 B9'];
frame = uint8(sscanf(hex, '%2x').');
stream = [hex2dec('35') hex2dec('BF') hex2dec('E4') ...
    hex2dec('50') hex2dec('05') hex2dec('BD') frame];

imu = decodeIMUFrameFromStream(stream);

verifyEqual(testCase, imu.tag, uint8(hex2dec('83')));
verifyEqual(testCase, imu.data_bitmap, uint32(hex2dec('11')));
verifyEqual(testCase, imu.acc_b_ms2, ...
    [0.021254 3.293 9.217], 'AbsTol', 1e-3);
verifyEqual(testCase, imu.q_wxyz, ...
    [0.985 0.171 -0.00164 -0.000339], 'AbsTol', 1e-3);

end

function testLiveSensorHeadersAcceptOnlyExpectedFootAndType(testCase)

verifyWarningFree(testCase, @() validateMqttSensorFrameHeader( ...
    uint8([hex2dec('40') hex2dec('31') 0]), "left", "pressure"));
verifyWarningFree(testCase, @() validateMqttSensorFrameHeader( ...
    uint8([hex2dec('40') hex2dec('32') 0]), "right", "pressure"));
verifyWarningFree(testCase, @() validateMqttSensorFrameHeader( ...
    uint8([hex2dec('5A') hex2dec('A5') 0]), "left", "imu"));
verifyWarningFree(testCase, @() validateMqttSensorFrameHeader( ...
    uint8([hex2dec('5A') hex2dec('A5') 0]), "right", "imu"));

end

function testLiveSensorHeaderRejectsWrongPressureFoot(testCase)

verifyError(testCase, @() validateMqttSensorFrameHeader( ...
    uint8([hex2dec('40') hex2dec('32') 0]), "left", "pressure"), ...
    'gait:SensorFrameHeaderMismatch');

end

function testLiveSensorHeaderRejectsPrefixBeforeImuFrame(testCase)

verifyError(testCase, @() validateMqttSensorFrameHeader( ...
    uint8([hex2dec('AA') hex2dec('5A') hex2dec('A5')]), "right", "imu"), ...
    'gait:SensorFrameHeaderMismatch');

end

function cfg = pressureRegionConfig()

cfg.heelRows = 1:3;
cfg.midRows = 4:7;
cfg.foreRows = 8:10;
cfg.toeRows = 11:12;
cfg.medialCols = 3:4;
cfg.lateralCols = 1:2;

end

function msg = sensorMsg(foot, sensorType, t)

msg.foot = foot;
msg.sensor_type = char(sensorType);
msg.recv_time_sec = t;

end

function cleanupTestState(key)

if isappdata(0, key)
    rmappdata(0, key);
end
close(findall(0, 'Type', 'figure', 'Visible', 'off'));

end

function restoreFigureVisibility(oldVisibility)

set(groot, 'DefaultFigureVisible', oldVisibility);
close(findall(0, 'Type', 'figure', 'Visible', 'off'));

end

function closeFigureIfValid(fig)

if ~isempty(fig) && isvalid(fig)
    close(fig);
end

end
