function tests = testGatewayTimeAlignment
% testGatewayTimeAlignment  Regression tests for gateway clock association.

tests = functiontests(localfunctions);

end

function testPassiveAlignmentMapsRightClockIntoLeftClock(testCase)

cfg.useTap = false;
cfg.passiveDurationSec = 1.0;
cfg.passiveMinSamplesPerFoot = 5;
cfg.maxSamplesPerFoot = 100;
state = initGatewayTimeAlignment(cfg);

rightClockLagSec = 0.125;
for k = 0:12
    commonT = 1000 + 0.1 * k;
    left = makeMessage("left", commonT, commonT + 0.040);
    right = makeMessage( ...
        "right", commonT - rightClockLagSec, commonT + 0.042);
    [state, ~, ~] = updateGatewayTimeAlignment(state, left, cfg);
    [state, ~, ~] = updateGatewayTimeAlignment(state, right, cfg);
end

verifyTrue(testCase, state.ready);
verifyEqual(testCase, state.mode, "passive");
verifyEqual(testCase, state.rightToLeftOffsetSec, ...
    rightClockLagSec + 0.002, 'AbsTol', 1e-9);

right = makeMessage("right", 2000, 2000.1);
[~, aligned, ~] = updateGatewayTimeAlignment(state, right, cfg);
verifyEqual(testCase, aligned.gateway_time_sec, 2000, 'AbsTol', 1e-12);
verifyEqual(testCase, aligned.recv_time_sec, ...
    2000 + rightClockLagSec + 0.002, 'AbsTol', 1e-9);
verifyEqual(testCase, aligned.aligned_time_sec, aligned.recv_time_sec);
verifyEqual(testCase, aligned.arrival_time_sec, 2000.1, 'AbsTol', 1e-12);
verifyTrue(testCase, aligned.time_alignment_ready);

end

function testTapAlignmentUsesPairedImpactGatewayTimes(testCase)

cfg.tapMinPairs = 3;
cfg.tapMinPeakMs2 = 3.0;
cfg.tapSigmaMultiplier = 5.0;
cfg.tapMinPeakSpacingSec = 0.35;
cfg.tapPairArrivalToleranceSec = 0.10;
cfg.tapMaxOffsetSpreadSec = 0.03;
cfg.tapMaxPeaksPerFoot = 10;

sampleT = (0:0.01:5).';
impactT = [0.8 1.7 2.6 3.5 4.4];
leftSignal = 9.80665 * ones(size(sampleT));
rightSignal = leftSignal;
for impact = impactT
    [~, idx] = min(abs(sampleT - impact));
    leftSignal(idx) = 28 + impact;
    rightSignal(idx + 1) = 27 + impact;
end

rightClockLagSec = 0.073;
left.gatewayT = 10000 + sampleT;
left.arrivalT = 20000 + sampleT + 0.010;
left.accNormMs2 = leftSignal;
right.gatewayT = 10000 + sampleT - rightClockLagSec;
right.arrivalT = 20000 + sampleT + 0.018;
right.accNormMs2 = rightSignal;

result = estimateTapGatewayOffset(left, right, cfg);

verifyTrue(testCase, result.success);
verifyGreaterThanOrEqual(testCase, result.pairCount, 3);
verifyEqual(testCase, result.rightToLeftOffsetSec, ...
    rightClockLagSec - 0.01, 'AbsTol', 1e-9);
verifyLessThanOrEqual(testCase, result.qualitySpreadSec, 1e-9);

end

function testPendingAlignmentKeepsArrivalAndGatewaySeparate(testCase)

cfg.useTap = true;
state = initGatewayTimeAlignment(cfg);
msg = makeMessage("left", 123.25, 456.75);

[~, mapped, event] = updateGatewayTimeAlignment(state, msg, cfg);

verifyFalse(testCase, event.completed);
verifyFalse(testCase, mapped.time_alignment_ready);
verifyEqual(testCase, mapped.recv_time_sec, 123.25, 'AbsTol', 1e-12);
verifyEqual(testCase, mapped.arrival_time_sec, 456.75, 'AbsTol', 1e-12);

end

function msg = makeMessage(foot, gatewayT, arrivalT)

msg.foot = char(foot);
msg.sensor_type = 'pressure';
msg.gateway_time_sec = gatewayT;
msg.gateway_time_str = "";
msg.arrival_time_sec = arrivalT;
msg.arrival_time_str = "";
msg.recv_time_sec = gatewayT;
msg.recv_time_str = "";

end
