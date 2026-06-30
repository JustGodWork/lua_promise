--- Internal engine for the Promise class: state settling, thenable adoption and
--- coroutine wakeups for `:Await()`. Handler dispatch is synchronous (no event
--- loop required); the only async primitive is the Lua coroutine that `:Await()`
--- parks and `settle` resumes.
---
--- An optional scheduler (see `set_timer`) is used ONLY by the time-based helpers
--- (`Promise.delay` / `:Timeout`) and the unhandled-rejection check — never for
--- the core then/chain machinery.
---
--- This module is NOT part of the public API. Game code should only ever touch
--- the `Promise` class (promise.class.lua) and the `async` / `await` globals.
--- Everything here operates on a promise table through its private fields, so it
--- stays decoupled from the class definition (no circular require).

local unpack <const> = table.unpack or unpack;

local PENDING   <const> = "pending";
local FULFILLED <const> = "fulfilled";
local REJECTED  <const> = "rejected";

---@class promise.utils
---@field on_unhandled? fun(reason: any, message: string) Hook invoked on an unhandled rejection.
local utils = {
    PENDING = PENDING,
    FULFILLED = FULFILLED,
    REJECTED = REJECTED,
};

--- Optional `set_timeout(callback, ms)` provided by the host. `nil` keeps the
--- library fully self-contained (synchronous dispatch + coroutine await); when
--- installed it powers the time-based helpers and deferred unhandled detection.
---@type (fun(callback: fun(), ms: integer))?
local set_timeout = nil;

--- Install (or clear, with `nil`) the optional scheduler. See `Promise.SetTimer`.
---@param fn (fun(callback: fun(), ms: integer))?
---@return void
function utils.set_timer(fn)
    assert(fn == nil or type(fn) == "function", "set_timer expects a function or nil.");
    set_timeout = fn;
end

--- The currently installed scheduler, or `nil` when none is set.
---@return (fun(callback: fun(), ms: integer))? set_timeout
function utils.get_timer()
    return set_timeout;
end

--- Is `value` one of our own promises? Detected through the instance metatable's
--- `__name`, so the check survives across packages/VMs.
---
--- ```lua
--- utils.is_promise(Promise.resolve(1)); -- true
--- ```
---@param value any
---@return boolean
function utils.is_promise(value)
    local mt <const> = type(value) == "table" and getmetatable(value) or nil;
    return mt ~= nil and mt.__name == "Promise";
end

--- Extract a callable `then`-style method from any thenable, so the engine can
--- adopt foreign promises (our own `:Then`, a `:next`, or a raw `then`).
---@private
---@param value table
---@return (fun(self: any, on_fulfilled: fun(value: any), on_rejected: fun(reason: any)))?
local function get_then(value)
    local fn <const> = value.Then or value.next or value["then"];
    if (type(fn) == "function") then
        return fn;
    end
    return nil;
end

--- A thenable is any table exposing a `Then` / `next` / `then` function. Used by
--- `resolve` to flatten nested promises and interoperate with other libraries.
---
--- ```lua
--- utils.is_thenable(SomeOtherLibPromise); -- true
--- ```
---@param value any
---@return boolean
function utils.is_thenable(value)
    return type(value) == "table" and get_then(value) ~= nil;
end

--- Resume every coroutine parked in `:Await()` on this promise. This is the
--- library's async engine: the awaiting code continues the instant the promise
--- settles, with no event loop involved.
---@private
---@param promise Promise
---@return void
local function wake_awaiters(promise)
    local awaiters <const> = promise._awaiters;
    if (not awaiters or #awaiters == 0) then
        return;
    end
    promise._awaiters = {};
    for i = 1, #awaiters do
        local co <const> = awaiters[i];
        if (coroutine.status(co) == "suspended") then
            local ok, err = coroutine.resume(co);
            if (not ok) then
                print(("[Promise] error after Await resume: %s"):format(tostring(err)));
            end
        end
    end
end

--- Best-effort unhandled-rejection warning. Needs a scheduler to defer the check
--- past the current call stack (so a handler attached on the next line still
--- counts as handled). Without one it is silently skipped.
---@private
---@param promise Promise
---@return void
local function flag_unhandled(promise)
    if (not set_timeout) then
        return;
    end
    set_timeout(function()
        if (promise._handled or promise._state ~= REJECTED) then
            return;
        end
        local reason <const> = promise._value;
        local message <const> = (type(reason) == "table" and (reason.message or reason.name))
            or tostring(reason);
        if (utils.on_unhandled) then
            utils.on_unhandled(reason, message);
        else
            print(("[Promise] Unhandled rejection: %s"):format(message));
        end
    end, 0);
end

--- Move a pending promise to its final state, dispatch every queued handler
--- synchronously, then wake awaiting coroutines. No-op once settled — the first
--- settle wins.
---
--- ```lua
--- utils.settle(p, utils.FULFILLED, 42);
--- ```
---@param promise Promise
---@param state "fulfilled"|"rejected"
---@param value any
---@return void
local function settle(promise, state, value)
    if (promise._state ~= PENDING) then
        return;
    end

    promise._state = state;
    promise._value = value;

    local queue <const> = promise._callbacks;
    promise._callbacks = {};
    for i = 1, #queue do
        queue[i](state, value);
    end

    wake_awaiters(promise);

    if (state == REJECTED) then
        flag_unhandled(promise);
    end
end

--- The Promises/A+ resolution procedure. Fulfils `promise` with `value`, unless
--- `value` is itself a thenable — then `promise` adopts its eventual state. Guards
--- against self-resolution cycles and a thenable that settles more than once.
---
--- ```lua
--- utils.resolve(outer, inner); -- outer mirrors inner's settlement
--- ```
---@param promise Promise
---@param value any
---@return void
local function resolve(promise, value)
    if (promise._state ~= PENDING) then
        return;
    end

    if (value == promise) then
        settle(promise, REJECTED, "TypeError: a promise cannot be resolved with itself");
        return;
    end

    if (utils.is_thenable(value)) then
        local then_fn <const> = get_then(value);
        local called = false;
        local ok, err = pcall(then_fn, value,
            function(v)
                if (not called) then
                    called = true;
                    resolve(promise, v);
                end
            end,
            function(r)
                if (not called) then
                    called = true;
                    settle(promise, REJECTED, r);
                end
            end
        );
        if (not ok and not called) then
            settle(promise, REJECTED, err);
        end
        return;
    end

    settle(promise, FULFILLED, value);
end

utils.settle = settle;
utils.resolve = resolve;
utils.unpack = unpack;

return utils;
