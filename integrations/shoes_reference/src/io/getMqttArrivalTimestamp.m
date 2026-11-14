function [arrivalSec, arrivalTimeStr] = getMqttArrivalTimestamp(rawMsg)
% getMqttArrivalTimestamp  Return the time captured when MQTT callback ran.

arrivalSec = NaN;
arrivalTimeStr = "";

if isstruct(rawMsg) && isfield(rawMsg, 'ArrivalEpochSec') && ...
        ~isempty(rawMsg.ArrivalEpochSec)
    arrivalSec = double(rawMsg.ArrivalEpochSec(1));
end
if isstruct(rawMsg) && isfield(rawMsg, 'ArrivalTimeStr') && ...
        ~isempty(rawMsg.ArrivalTimeStr)
    arrivalTimeStr = string(rawMsg.ArrivalTimeStr);
end

if ~isfinite(arrivalSec) && isstruct(rawMsg) && ...
        isfield(rawMsg, 'ArrivalTime') && ~isempty(rawMsg.ArrivalTime)
    try
        if isdatetime(rawMsg.ArrivalTime)
            arrivalDt = rawMsg.ArrivalTime(1);
        else
            arrivalDt = datetime(double(rawMsg.ArrivalTime(1)), ...
                'ConvertFrom', 'datenum', 'TimeZone', 'local');
        end
        arrivalSec = posixtime(arrivalDt);
        if strlength(arrivalTimeStr) == 0
            arrivalTimeStr = string(arrivalDt, 'yyyy-MM-dd HH:mm:ss.SSS');
        end
    catch
    end
end

if ~isfinite(arrivalSec)
    arrivalDt = datetime('now', 'TimeZone', 'local', ...
        'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
    arrivalSec = posixtime(arrivalDt);
    arrivalTimeStr = string(arrivalDt);
elseif strlength(arrivalTimeStr) == 0
    arrivalDt = datetime(arrivalSec, 'ConvertFrom', 'posixtime', ...
        'TimeZone', 'local', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
    arrivalTimeStr = string(arrivalDt);
end

end
