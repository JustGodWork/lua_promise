---@param promise Promise
---@param value any
local function resolve(promise, value)
    if (promise._state ~= "pending") then
        return;
    end

    promise._value = value;
    promise._state = "fulfilled";
    promise._process(promise._value);
end

---@param promise Promise
---@param reason any
local function reject(promise, reason)
    if (promise._state ~= "pending") then
        return;
    end

    promise._reason = reason;
    promise._state = "rejected";
    promise._process(nil, promise._reason);
end

---@param promise Promise
local function initialize(promise)
    promise._process = function(value, reason)
        if (type(promise._thread) == "thread") then
            coroutine.resume(promise._thread, promise._state == "fulfilled" and promise._value or nil, promise._reason);
        end
        for i = #promise._callbacks, 1, -1 do
            local callback = promise._callbacks[i];
            if (type(callback) == "function") then
                callback(value, reason);
            end
            table.remove(promise._callbacks, i);
        end
    end
end

---@class promise.utils
---@field resolve fun(promise: Promise, value: any)
---@field reject fun(promise: Promise, reason: any)
---@field initialize fun(promise: Promise)
return {
    resolve = resolve,
    reject = reject,
    initialize = initialize,
};