--- Showcase of the Promise API. Mirrors what you can do with a JavaScript
--- Promise, plus the coroutine-based `:Await()` / `async` / `await` sugar.

require "promise.class.lua"; -- Implement your own require path

--- A fake async job: counts to `target`, then calls back. Half the time it
--- "fails" to demonstrate rejection paths.
---@param target integer
---@param callback fun(ok: boolean, count: integer)
local function count_async(target, callback)
    local count = 0;
    while (count < target) do
        count = count + 1;
    end
    callback(math.random(1, 2) == 1, count);
end

--- 1. Executor style — wrap a callback API into a promise.
---@return Promise
local function count(target)
    return Promise(function(resolve, reject)
        count_async(target, function(ok, value)
            if (ok) then
                resolve(value);
            else
                reject(("count(%d) failed"):format(target));
            end
        end);
    end);
end

--- 2. Deferred style — get a handle now, settle it later.
---@return Promise
local function count_deferred(target)
    local promise <const> = Promise();
    count_async(target, function(_, value) promise:Resolve(value); end);
    return promise;
end

-- Chaining: each :Then receives the previous return value.
count(10)
    :Then(function(value) return value * 2; end)
    :Then(function(doubled) print(("chained result: %d"):format(doubled)); end)
    :Catch(function(reason) print(("chain failed: %s"):format(reason)); end)
    :Finally(function() print("chain settled"); end);

-- Combinators, JavaScript-style.
Promise.all({ count(5), count(10), count_deferred(15) })
    :Then(function(values) print(("all done: %d/%d/%d"):format(values[1], values[2], values[3])); end)
    :Catch(function(reason) print(("one of them failed: %s"):format(reason)); end);

Promise.allSettled({ count(5), count(10) })
    :Then(function(results)
        for i, r in ipairs(results) do
            print(("[%d] %s -> %s"):format(i, r.status, tostring(r.value or r.reason)));
        end
    end);

Promise.race({ count(5), count(50) })
    :Then(function(winner) print(("race winner: %d"):format(winner)); end);

-- Sequential async/await flow inside a coroutine. `async` itself returns a
-- promise resolving to the function's return value.
async(function()
    local a <const> = count(5):Await();
    local b <const> = await(count_deferred(10)); -- global await works on any thenable
    return a + b;
end)
    :Then(function(total) print(("async total: %d"):format(total)); end)
    :Catch(function(reason) print(("async failed: %s"):format(reason)); end);

-- Timers (require a scheduler installed via Promise.SetTimer).
async(function()
    Promise.delay(1000):Await();
    print("one second later");
end);

count(100):Timeout(2000, "took too long")
    :Catch(function(reason) print(("timed out: %s"):format(reason)); end);
