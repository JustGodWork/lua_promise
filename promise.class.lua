--- A complete, dependency-free Promise implementation modelled on the JavaScript
--- Promise (Promises/A+ chaining, thenable adoption, the full combinator set)
--- plus extras: coroutine `:Await()`, `:Tap`, `:Timeout`, `Promise.delay`,
--- `Promise.try`, `Promise.map` and a configurable unhandled-rejection hook.
---
--- The async engine is the Lua coroutine: `:Await()` parks the running coroutine
--- and the promise resumes it on settle. Handler dispatch (`:Then`) is
--- synchronous, so the core needs no event loop. Only the time-based helpers
--- (`Promise.delay`, `:Timeout`) require a scheduler, installed via
--- `Promise.SetTimer`.
---
--- Public method names stay PascalCase (`:Then`, `:Catch`, `:Await`, ...) for
--- backward compatibility; the static factories mirror JS spelling
--- (`Promise.resolve`, `Promise.all`, ...). A lowercase `:await()` alias exists
--- for interop with code that expects it.

---@type promise.utils
local utils <const> = require "promise.utils.lua"; -- Implement your own require path

local unpack <const> = utils.unpack;

local PENDING   <const> = utils.PENDING;
local FULFILLED <const> = utils.FULFILLED;
local REJECTED  <const> = utils.REJECTED;

--- A value that proxies the eventual result of an asynchronous operation. Create
--- one with an executor, or as a deferred handle controlled with `:Resolve` /
--- `:Reject`.
---
--- ```lua
--- -- executor style (preferred)
--- local p <const> = Promise(function(resolve, reject)
---     some_async(function(value) resolve(value); end);
--- end);
---
--- -- deferred style
--- local d <const> = Promise();
--- some_async(function(value) d:Resolve(value); end);
--- ```
---@class Promise
---@field private _state "pending"|"fulfilled"|"rejected"
---@field private _value any The fulfilment value or the rejection reason.
---@field private _callbacks (fun(state: string, value: any))[]
---@field private _awaiters thread[]
---@field private _handled boolean Whether the rejection path has been observed.
---@overload fun(executor?: fun(resolve: fun(value: any), reject: fun(reason: any))): Promise
Promise = setmetatable({}, {
    __call = function(cls, executor)
        local self <const> = setmetatable({}, { __index = cls, __name = "Promise" });
        self._state = PENDING;
        self._value = nil;
        self._callbacks = {};
        self._awaiters = {};
        self._handled = false;
        if (type(executor) == "function") then
            local ok, err = pcall(executor,
                function(value) utils.resolve(self, value); end,
                function(reason) utils.settle(self, REJECTED, reason); end
            );
            if (not ok) then
                utils.settle(self, REJECTED, err);
            end
        end
        return self;
    end
});

--- Settle a deferred promise with a value (adopting it if it is itself a
--- thenable). No-op if the promise is already settled. Returns the promise so
--- calls can be chained.
---
--- ```lua
--- local p <const> = Promise();
--- p:Resolve(42);
--- ```
---@param value any
---@return Promise self
function Promise:Resolve(value)
    utils.resolve(self, value);
    return self;
end

--- Settle a deferred promise as rejected. No-op if already settled. Returns the
--- promise so calls can be chained.
---
--- ```lua
--- local p <const> = Promise();
--- p:Reject("boom");
--- ```
---@param reason any
---@return Promise self
function Promise:Reject(reason)
    utils.settle(self, REJECTED, reason);
    return self;
end

--- The current lifecycle state. Mostly useful for debugging/introspection.
---
--- ```lua
--- if (p:GetState() == "pending") then ... end
--- ```
---@return "pending"|"fulfilled"|"rejected" state
function Promise:GetState()
    return self._state;
end

--- True once the promise has left the pending state (either way).
---
--- ```lua
--- local done <const> = p:IsSettled();
--- ```
---@return boolean settled
function Promise:IsSettled()
    return self._state ~= PENDING;
end

--- Attach fulfilment and/or rejection handlers and return a NEW promise for the
--- handler's result, enabling chaining. A handler that throws rejects the chain;
--- a handler that returns a promise is awaited (flattened). Missing handlers pass
--- the value/reason straight through to the next promise.
---
--- ```lua
--- fetch_user(id)
---     :Then(function(user) return user.name; end)
---     :Then(function(name) print(name); end);
--- ```
---@param on_fulfilled? fun(value: any): any
---@param on_rejected? fun(reason: any): any
---@return Promise next
function Promise:Then(on_fulfilled, on_rejected)
    -- Attaching any handler transfers responsibility for the rejection to the
    -- returned promise, so this one is no longer "unhandled".
    self._handled = true;

    return Promise(function(resolve, reject)
        local function handle(state, value)
            local handler <const> = (state == FULFILLED) and on_fulfilled or on_rejected;
            if (type(handler) ~= "function") then
                if (state == FULFILLED) then
                    resolve(value);
                else
                    reject(value);
                end
                return;
            end
            local ok, result = pcall(handler, value);
            if (ok) then
                resolve(result);
            else
                reject(result);
            end
        end

        if (self._state == PENDING) then
            self._callbacks[#self._callbacks + 1] = handle;
        else
            handle(self._state, self._value);
        end
    end);
end

--- Sugar for `:Then(nil, on_rejected)` — handle a rejection while letting
--- fulfilment pass through.
---
--- ```lua
--- risky():Catch(function(err) print("failed:", err); end);
--- ```
---@param on_rejected fun(reason: any): any
---@return Promise next
function Promise:Catch(on_rejected)
    return self:Then(nil, on_rejected);
end

--- Run `on_finally` once the promise settles, whatever the outcome, then pass
--- the original value/reason through unchanged. If `on_finally` returns a
--- promise, settlement waits for it (matching JS).
---
--- ```lua
--- show_spinner();
--- load():Finally(function() hide_spinner(); end);
--- ```
---@param on_finally fun(): any?
---@return Promise next
function Promise:Finally(on_finally)
    return self:Then(
        function(value)
            if (type(on_finally) ~= "function") then
                return value;
            end
            return Promise.resolve(on_finally()):Then(function() return value; end);
        end,
        function(reason)
            if (type(on_finally) ~= "function") then
                return Promise.reject(reason);
            end
            return Promise.resolve(on_finally()):Then(function() return Promise.reject(reason); end);
        end
    );
end

--- Run a side effect on fulfilment and forward the original value untouched
--- (the side effect's own return value is ignored, but awaited if it is a
--- promise). Great for logging or metrics inside a chain.
---
--- ```lua
--- fetch():Tap(function(v) print("got", v); end):Then(use);
--- ```
---@param on_fulfilled fun(value: any): any?
---@return Promise next
function Promise:Tap(on_fulfilled)
    return self:Then(function(value)
        if (type(on_fulfilled) ~= "function") then
            return value;
        end
        return Promise.resolve(on_fulfilled(value)):Then(function() return value; end);
    end);
end

--- Race this promise against a timeout. Resolves/rejects with this promise if it
--- settles within `ms`, otherwise rejects with `reason`. Requires a scheduler
--- (see `Promise.SetTimer`) to actually time out.
---
--- ```lua
--- slow_request():Timeout(5000, "request timed out"):Catch(handle);
--- ```
---@param ms integer
---@param reason? any
---@return Promise next
function Promise:Timeout(ms, reason)
    return Promise.timeout(self, ms, reason);
end

--- Block the current coroutine until the promise settles, then return its value
--- — or re-raise its rejection reason as an error (so `pcall`/`async` can catch
--- it, just like JS `await`). MUST run inside a coroutine (use `async`).
---
--- ```lua
--- async(function()
---     local user <const> = fetch_user(1):Await();
---     print(user.name);
--- end);
--- ```
---@return any value
function Promise:Await()
    self._handled = true; -- awaiting consumes the rejection, settled or not
    if (self._state == PENDING) then
        local co <const>, is_main <const> = coroutine.running();
        assert(not is_main, "Promise:Await must run inside a coroutine (wrap it in async()).");
        self._awaiters[#self._awaiters + 1] = co;
        coroutine.yield();
    end
    if (self._state == REJECTED) then
        error(self._value, 0);
    end
    return self._value;
end

--- Lowercase alias of `:Await()` for interop with code (e.g. Norm, ParallelHook)
--- that calls `promise:await()`.
---@return any value
Promise.await = Promise.Await;

--- Return a promise resolved with `value`. If `value` is already one of our
--- promises it is returned as-is; a foreign thenable is adopted.
---
--- ```lua
--- Promise.resolve(42):Then(print);
--- ```
---@param value any
---@return Promise
function Promise.resolve(value)
    if (utils.is_promise(value)) then
        return value;
    end
    return Promise(function(resolve) resolve(value); end);
end

--- Return a promise already rejected with `reason`.
---
--- ```lua
--- Promise.reject("nope"):Catch(print);
--- ```
---@param reason any
---@return Promise
function Promise.reject(reason)
    return Promise(function(_, reject) reject(reason); end);
end

--- Is `value` one of our promises?
---
--- ```lua
--- if (Promise.is(x)) then x:Then(use); end
--- ```
---@param value any
---@return boolean
function Promise.is(value)
    return utils.is_promise(value);
end

--- Wait for every promise in the list to fulfil and resolve with an ordered
--- array of their values. Rejects as soon as any one rejects. Non-promise items
--- are treated as already-resolved values. Resolves immediately for an empty
--- list.
---
--- ```lua
--- local all <const> = Promise.all({ load_a(), load_b(), load_c() }):Await();
--- ```
---@param promises any[]
---@return Promise
function Promise.all(promises)
    return Promise(function(resolve, reject)
        local list <const> = promises or {};
        local count <const> = #list;
        local results <const> = {};
        local remaining = count;
        if (count == 0) then
            resolve(results);
            return;
        end
        for i = 1, count do
            Promise.resolve(list[i]):Then(function(value)
                results[i] = value;
                remaining = remaining - 1;
                if (remaining == 0) then
                    resolve(results);
                end
            end, reject);
        end
    end);
end

--- Wait for every promise to settle (never rejects) and resolve with an array of
--- result descriptors: `{ status = "fulfilled", value = ... }` or
--- `{ status = "rejected", reason = ... }`.
---
--- ```lua
--- for _, r in ipairs(Promise.allSettled(jobs):Await()) do
---     if (r.status == "fulfilled") then use(r.value); end
--- end
--- ```
---@param promises any[]
---@return Promise
function Promise.allSettled(promises)
    return Promise(function(resolve)
        local list <const> = promises or {};
        local count <const> = #list;
        local results <const> = {};
        local remaining = count;
        if (count == 0) then
            resolve(results);
            return;
        end
        local function record(i, descriptor)
            results[i] = descriptor;
            remaining = remaining - 1;
            if (remaining == 0) then
                resolve(results);
            end
        end
        for i = 1, count do
            Promise.resolve(list[i]):Then(function(value)
                record(i, { status = FULFILLED, value = value });
            end, function(reason)
                record(i, { status = REJECTED, reason = reason });
            end);
        end
    end);
end

--- Settle with the first promise to settle, whatever its outcome (fulfilment or
--- rejection). Stays pending forever on an empty list (as in JS).
---
--- ```lua
--- Promise.race({ work(), Promise.delay(1000):Then(timeout) }):Await();
--- ```
---@param promises any[]
---@return Promise
function Promise.race(promises)
    return Promise(function(resolve, reject)
        local list <const> = promises or {};
        for i = 1, #list do
            Promise.resolve(list[i]):Then(resolve, reject);
        end
    end);
end

--- Resolve with the first promise to FULFIL. If they all reject, reject with an
--- AggregateError-like table `{ name, message, errors }`.
---
--- ```lua
--- local first <const> = Promise.any({ mirror_a(), mirror_b() }):Await();
--- ```
---@param promises any[]
---@return Promise
function Promise.any(promises)
    return Promise(function(resolve, reject)
        local list <const> = promises or {};
        local count <const> = #list;
        local errors <const> = {};
        local remaining = count;
        local function reject_all()
            reject({ name = "AggregateError", message = "All promises were rejected", errors = errors });
        end
        if (count == 0) then
            reject_all();
            return;
        end
        for i = 1, count do
            Promise.resolve(list[i]):Then(resolve, function(reason)
                errors[i] = reason;
                remaining = remaining - 1;
                if (remaining == 0) then
                    reject_all();
                end
            end);
        end
    end);
end

--- Run `fn` (with optional args) and capture its result in a promise: a return
--- value resolves it, a thrown error rejects it, a returned promise is adopted.
--- Lets a maybe-throwing synchronous call join a promise chain safely.
---
--- ```lua
--- Promise.try(decode, raw):Catch(function(err) print("bad json", err); end);
--- ```
---@param fn fun(...): any
---@param ... any
---@return Promise
function Promise.try(fn, ...)
    local args <const> = { ... };
    local n <const> = select("#", ...);
    return Promise(function(resolve)
        resolve(fn(unpack(args, 1, n)));
    end);
end

--- Map `list` through `mapper(value, index)` (each result may be a promise) and
--- resolve with all mapped values once they settle. Rejects on the first error.
---
--- ```lua
--- local names <const> = Promise.map(ids, function(id) return fetch_name(id); end):Await();
--- ```
---@param list any[]
---@param mapper fun(value: any, index: integer): any
---@return Promise
function Promise.map(list, mapper)
    local source <const> = list or {};
    local mapped <const> = {};
    for i = 1, #source do
        mapped[i] = Promise.resolve(source[i]):Then(function(value)
            return mapper(value, i);
        end);
    end
    return Promise.all(mapped);
end

--- Resolve with `value` after `ms` milliseconds. Time-based, so it requires a
--- scheduler (see `Promise.SetTimer`); with no scheduler installed this raises.
---
--- ```lua
--- async(function() Promise.delay(500):Await(); print("half a second later"); end);
--- ```
---@param ms integer
---@param value? any
---@return Promise
function Promise.delay(ms, value)
    local set_timeout <const> = utils.get_timer();
    assert(set_timeout, "Promise.delay requires a scheduler; call Promise.SetTimer(...) first.");
    return Promise(function(resolve)
        set_timeout(function() resolve(value); end, ms or 0);
    end);
end

--- Reject `promise` with `reason` if it has not settled within `ms`; otherwise
--- mirror it. Built on `Promise.race` + `Promise.delay`.
---
--- ```lua
--- Promise.timeout(load(), 3000, "too slow"):Catch(handle);
--- ```
---@param promise any
---@param ms integer
---@param reason? any
---@return Promise
function Promise.timeout(promise, ms, reason)
    return Promise.race({
        Promise.resolve(promise),
        Promise.delay(ms):Then(function()
            return Promise.reject(reason or ("Promise timed out after %dms"):format(ms or 0));
        end),
    });
end

--- Install the optional scheduler used by the time-based helpers (`Promise.delay`,
--- `:Timeout`) and the deferred unhandled-rejection check. `set_timeout(callback,
--- ms)` must schedule `callback` to run after `ms` milliseconds. The library is
--- otherwise pure Lua (synchronous dispatch, coroutine `:Await()`); without a
--- scheduler the time-based helpers raise. Pass `nil` to remove it.
---
--- ```lua
--- -- plug in your host's event-loop timer:
--- Promise.SetTimer(function(callback, ms) host_set_timeout(callback, ms); end);
--- ```
---@param set_timeout (fun(callback: fun(), ms: integer))?
---@return void
function Promise.SetTimer(set_timeout)
    utils.set_timer(set_timeout);
end

--- Register a global handler for rejections that are never observed (no `:Catch`,
--- `:Then(_, on_rejected)` or `:Await`). Detection only runs when a scheduler is
--- installed (see `Promise.SetTimer`). Pass `nil` to restore the default `print`.
---
--- ```lua
--- Promise.OnUnhandledRejection(function(reason, message)
---     log_error(("Unhandled promise rejection: %s"):format(message));
--- end);
--- ```
---@param handler? fun(reason: any, message: string)
---@return void
function Promise.OnUnhandledRejection(handler)
    utils.on_unhandled = handler;
end

--- Run `handler` inside a fresh coroutine so it may `:Await()` promises, and
--- return a promise for its result: the handler's return value resolves it, a
--- raised/awaited error rejects it. Extra arguments are forwarded to `handler`.
---
--- ```lua
--- local done <const> = async(function()
---     local a <const> = step_one():Await();
---     return step_two(a):Await();
--- end);
--- done:Then(function(result) print("pipeline done:", result); end);
--- ```
---@param handler fun(...): any
---@param ... any
---@return Promise
function async(handler, ...)
    assert(type(handler) == "function", "async: handler must be a function.");
    local args <const> = { ... };
    local n <const> = select("#", ...);
    return Promise(function(resolve, reject)
        local co <const> = coroutine.create(function()
            local ok, result = pcall(handler, unpack(args, 1, n));
            if (ok) then
                resolve(result);
            else
                reject(result);
            end
        end);
        local ok, err = coroutine.resume(co);
        if (not ok) then
            reject(err);
        end
    end);
end

--- Unwrap a promise (or any thenable) from inside a coroutine, returning its
--- resolved value or re-raising its rejection. A non-promise value is returned
--- unchanged (matching JS `await`).
---
--- ```lua
--- async(function()
---     local value <const> = await(some_promise);
--- end);
--- ```
---@param value any
---@return any
function await(value)
    if (utils.is_promise(value)) then
        return value:Await();
    end
    if (utils.is_thenable(value)) then
        return Promise.resolve(value):Await();
    end
    return value;
end
