# Lua Promise

A complete, dependency-free Promise implementation in **pure Lua**. It mirrors the
JavaScript `Promise` — Promises/A+ chaining, thenable adoption, the full
combinator set (`all` / `allSettled` / `race` / `any`) — and adds a coroutine-based
`:Await()` / `async` / `await` flow plus a few Bluebird-style extras (`Tap`,
`Timeout`, `delay`, `try`, `map`).

The **async engine is the Lua coroutine**: `:Await()` parks the running coroutine
and the promise resumes it on settle — no event loop involved. Handler dispatch
(`:Then`) is synchronous, so chaining, combinators and `async`/`await` work out of
the box, including in plain Lua and unit tests. Only the time-based helpers
(`delay`, `timeout`) need a scheduler — install one with `Promise.SetTimer` (see
below).

## Install

`require` the module, then expose `Promise`, `async` and `await` however your host
shares globals. The bundled host entry point (`Index.lua`) does this and wires a
scheduler; for other hosts, do the equivalent yourself.

> `promise.class.lua` requires `promise.utils.lua` from the same folder. Adjust
> the require paths to your loader if needed.

## Creating a promise

```lua
-- Executor style (recommended): wrap a callback API.
local p = Promise(function(resolve, reject)
    do_async(function(err, value)
        if (err) then reject(err); else resolve(value); end
    end);
end);

-- Deferred style: get the handle now, settle it later.
local d = Promise();
do_async(function(_, value) d:Resolve(value); end);

-- Static factories.
Promise.resolve(42);
Promise.reject("nope");
```

## Chaining

`:Then` always returns a **new** promise, so chains transform values, recover
from errors, and flatten nested promises automatically.

```lua
fetch_user(id)
    :Then(function(user) return user.name; end)      -- transform
    :Then(function(name) return load_avatar(name); end) -- return a promise -> flattened
    :Catch(function(err) return default_avatar; end)  -- recover
    :Finally(function() hide_spinner(); end);         -- always runs
```

| Method | Description |
|---|---|
| `:Then(onFulfilled, onRejected)` | Attach handlers, return a chained promise. |
| `:Catch(onRejected)` | Sugar for `:Then(nil, onRejected)`. |
| `:Finally(onFinally)` | Run on settle, pass value/reason through. |
| `:Tap(onFulfilled)` | Side-effect on fulfilment, forward the value. |
| `:Timeout(ms, reason?)` | Reject if not settled within `ms`. |
| `:Resolve(value)` / `:Reject(reason)` | Settle a deferred promise. |
| `:Await()` / `:await()` | Block the current coroutine for the value (re-raises rejections). |
| `:GetState()` / `:IsSettled()` | Introspection. |

## Combinators (static)

```lua
Promise.all({ a, b, c })        -- array of values, rejects on first failure
Promise.allSettled({ a, b })    -- { {status="fulfilled", value=}, {status="rejected", reason=} }
Promise.race({ a, b })          -- first to settle (either way)
Promise.any({ a, b })           -- first to FULFIL, else AggregateError
Promise.map(list, mapper)       -- map (mapper may return promises), then all
Promise.try(fn, ...)            -- run fn safely into a promise
Promise.delay(ms, value?)       -- resolve after a delay (needs a scheduler)
Promise.timeout(p, ms, reason?) -- race p against a timeout (needs a scheduler)
Promise.resolve(v) / Promise.reject(r) / Promise.is(v)
```

## Scheduler (for the time-based helpers)

Everything works without a scheduler except `Promise.delay` / `Promise.timeout`,
which are inherently time-based. Enable them by handing the library a
`set_timeout(callback, ms)` from your host's event loop:

```lua
-- plug your loop's timer (a game tick, luv, copas, ...)
Promise.SetTimer(my_set_timeout);

-- remove it
Promise.SetTimer(nil);
```

Installing a scheduler also enables deferred unhandled-rejection detection.
Without one, `Promise.delay` / `Promise.timeout` raise; every other feature still
works.

## async / await

`async` runs a function in a coroutine so it can `:Await()`, and itself returns a
promise for the function's result.

```lua
local job = async(function()
    local user = fetch_user(1):Await();
    local posts = await(fetch_posts(user.id)); -- global await: any thenable
    return #posts;
end);

job:Then(function(n) print(("loaded %d posts"):format(n)); end)
   :Catch(function(err) print("failed:", err); end);
```

A rejected promise awaited inside `async` raises an error you can `pcall`, exactly
like JavaScript `try/await`.

## Unhandled rejections

When a scheduler is installed, a rejection that is never observed (no `:Catch`,
`:Then(_, onRejected)` or `:Await`) is reported. Customise the handler:

```lua
Promise.OnUnhandledRejection(function(reason, message)
    log_error(("Unhandled promise rejection: %s"):format(message));
end);
```

## Interop

The instance metatable carries `__name == "Promise"`, and a generic thenable
adoption layer recognises `Then` / `next` / `then`, so foreign promises flow
through `Promise.all`, `:Then`, `await`, etc.

## License

MIT.

## Contact

- Discord: [JustForDev](https://discord.gg/nstjC2NBPf)
- GitHub: [JustGodWork](https://github.com/JustGodWork)
