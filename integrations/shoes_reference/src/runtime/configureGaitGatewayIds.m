function cfg = configureGaitGatewayIds(cfg, leftGatewayId, rightGatewayId)
% configureGaitGatewayIds  Build MQTT topics and foot mapping from gateway IDs.

leftGatewayId = normalizeGatewayId(leftGatewayId, "left");
rightGatewayId = normalizeGatewayId(rightGatewayId, "right");

if leftGatewayId == rightGatewayId
    error('gait:DuplicateGatewayId', ...
        'Left and right gateway IDs must be different.');
end

cfg.mqtt.gatewayIds.left = leftGatewayId;
cfg.mqtt.gatewayIds.right = rightGatewayId;
cfg.mqtt.topics.leftImu = "D2S/U/1/" + leftGatewayId;
cfg.mqtt.topics.rightImu = "D2S/U/1/" + rightGatewayId;
cfg.mqtt.topics.leftPressure = "D2S/U/0/" + leftGatewayId;
cfg.mqtt.topics.rightPressure = "D2S/U/0/" + rightGatewayId;

cfg.devices = struct([]);
cfg.devices(1).id = leftGatewayId;
cfg.devices(1).foot = "left";
cfg.devices(2).id = rightGatewayId;
cfg.devices(2).foot = "right";

end

function gatewayId = normalizeGatewayId(value, side)

gatewayId = upper(strip(string(value)));
if ~isscalar(gatewayId) || ismissing(gatewayId)
    error('gait:InvalidGatewayId', ...
        '%s gateway ID must be one text value.', char(side));
end

gatewayId = regexprep(gatewayId, '[:\-\s]', '');
if strlength(gatewayId) ~= 12 || ...
        isempty(regexp(char(gatewayId), '^[0-9A-F]{12}$', 'once'))
    error('gait:InvalidGatewayId', ...
        '%s gateway ID must contain exactly 12 hexadecimal characters.', ...
        char(side));
end

end
