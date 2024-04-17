---@type promise.utils
local utils = require "promise.utils.lua"; -- Implement your own require path

---<h4>Create a new promise</h4>
---@class Promise: BaseClass
---@field private _state string
---@field private _value any
---@field private _reason any
---@field private _callbacks fun[]
---@field private _thread thread
---@field private _process fun(value: any, reason: any)
---@overload fun(handlerFn: fun(resolve: fun(value: any), reject: fun(reason: any)): void): Promise
Promise = setmetatable({}, {
    __call = function(self, ...)
        local instance = setmetatable({}, { __index = self, __name = "Promise" });
        local constructor = rawget(self, "Constructor");
        if (constructor) then
            constructor(instance, ...);
        end
        return instance;
    end
});

---@private
---@param handlerFn? fun(resolve: fun(value: any), reject: fun(reason: any))
function Promise:Constructor(handlerFn)
    self._state = "pending";
    self._callbacks = {};
    if (type(handlerFn) == "function") then
        handlerFn(function(value)
            utils.resolve(self, value);
        end, function(reason)
            utils.reject(self, reason);
        end);
    end
    utils.initialize(self);
end

---<h4>Prepare the current promise to return setted value</h4>
---@param value any
function Promise:Resolve(value)
    utils.resolve(self, value);
    return self;
end

---<h4>Prepare the current promise to return setted reject reason</h4>
---@param reason any
function Promise:Reject(reason)
    utils.reject(self, reason);
    return self;
end

---<h4>Attach both resolve & reject callbacks to the promise</h4>
---@param onFulfilled? fun(value: any)
---@param onRejected? fun(reason: any)
function Promise:Then(onFulfilled, onRejected)
    if (self._state == "pending") then
        self._callbacks[#self._callbacks + 1] = function(value, reason)
            if (value) then
                if (type(onFulfilled) == "function") then
                    onFulfilled(value);
                end
            else
                if (type(onRejected) == "function") then
                    onRejected(reason);
                end
            end
        end
    end
    return self;
end

---<h4>Attach a reject callback to the promise</h4>
---@param onRejected fun(reason: any)
function Promise:Catch(onRejected)
    assert(type(onRejected) == "function", "Promise: Catch: onRejected must be a function.");
    self:Then(nil, onRejected);
    return self;
end

---<h4>Await the result and return it</h4>
---@return any value
function Promise:Await()
    local coro, is_main = coroutine.running();
    assert(not is_main, "You can't create a promise in the main thread.");
    self._thread = coro;
    if (self._state == "pending") then
        coroutine.yield();
    end
    return self._value;
end

---@param handlerFn function
function async(handlerFn)
    local thread = coroutine.create(function()
        assert(type(handlerFn) == "function", "Promise (AsyncThread): Handler function must be a function.");
        local status, result = pcall(handlerFn);
        if (not status) then
            print(("An error occurred in async function: (%s, stack: %s)"):format(handlerFn, result));
        end
        return result;
    end);
    coroutine.resume(thread);
end

---@param promise Promise
---@return any promise_value
function await(promise)
    local metatable = type(promise) == "table" and getmetatable(promise) or nil;
    assert(metatable and metatable.__name == "Promise", ("await: attempt to index a '%s' value 'promise'"):format(type(promise)));
    return promise:Await();
end