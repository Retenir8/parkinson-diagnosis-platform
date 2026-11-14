function requestGaitSessionShutdown(fig, appdataKey)
% requestGaitSessionShutdown  Close the UI and request a flushed shutdown.

% During an active run the key exists and the main loop consumes this
% command.  After cleanup, closing a retained terminal window must not
% recreate root appdata that no loop can consume.
if isappdata(0, appdataKey)
    setappdata(0, appdataKey, 'shutdown');
end
if ~isempty(fig) && isvalid(fig)
    delete(fig);
end

end
