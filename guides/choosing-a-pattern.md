# Choosing a Pattern

Resiliency ships five modules that each solve a distinct reliability or
concurrency problem.  This guide helps you pick the right one -- or the right
combination -- for your situation.

## Decision Tree

Start from the problem you are trying to solve and follow the branch.

---

### "My requests sometimes fail"

Use **`Resiliency.BackoffRetry`** -- retry the operation with configurable
backoff so you do not hammer the downstream service.

```elixir
Resiliency.BackoffRetry.retry(
  fn ->
    case HttpClient.get(url) do
      {:ok, %{status: 200}} = ok -> ok
      {:ok, %{status: 503}}      -> {:error, :unavailable}
      {:error, reason}           -> {:error, reason}
    end
  end,
  max_attempts: 4,
  backoff: :exponential,
  base_delay: 200,
  retry_if: fn
    {:error, :unavailable} -> true
    {:error, :timeout}     -> true
    _                      -> false
  end
)
```

Key traits:

- Adds latency (each retry waits for the backoff delay).
- Does **not** add concurrent load -- attempts are sequential.
- Stateless -- no process to start.

---

### "My requests are sometimes slow"

Use **`Resiliency.Hedged`** -- send a backup request after a delay, take
whichever finishes first, cancel the loser.  This is a tail-latency
optimization, not a retry strategy.

```elixir
# Adaptive mode -- delay auto-tunes from observed latency
{:ok, _} = Resiliency.Hedged.start_link(name: MyHedge, percentile: 95)

{:ok, body} = Resiliency.Hedged.run(MyHedge, fn ->
  HttpClient.get!(url)
end)
```

```elixir
# Stateless mode -- fixed delay, no process needed
{:ok, body} = Resiliency.Hedged.run(fn -> HttpClient.get!(url) end, delay: 50)
```

Key traits:

- Reduces tail latency at the cost of extra requests.
- **Does** add load -- a hedge fires a second (or Nth) request.
- Adaptive mode is stateful (a `GenServer` tracker); stateless mode is not.

---

### "Multiple callers request the same thing at the same time"

Use **`Resiliency.SingleFlight`** -- deduplicate concurrent calls so the
function executes only once per key, and all waiters share the result.

```elixir
{:ok, _} = Resiliency.SingleFlight.start_link(name: MyFlights)

{:ok, user} = Resiliency.SingleFlight.flight(MyFlights, "user:123", fn ->
  Repo.get!(User, 123)
end)
```

Key traits:

- Reduces load -- N concurrent callers produce exactly 1 execution.
- Saves latency for callers that arrive after the first -- they skip the I/O
  entirely and receive the result as soon as the in-flight call completes.
- Stateful -- requires a `GenServer`.

---

### "I need to limit concurrent access to a resource"

Use **`Resiliency.WeightedSemaphore`** -- bound concurrency with per-operation
weights and FIFO fairness.

```elixir
children = [{Resiliency.WeightedSemaphore, name: MyApp.DbPool, max: 10}]
Supervisor.start_link(children, strategy: :one_for_one)

# Lightweight read -- 1 permit
{:ok, row} = Resiliency.WeightedSemaphore.acquire(MyApp.DbPool, 1, fn ->
  Repo.get(User, id)
end)

# Heavy bulk insert -- 5 permits
{:ok, _} = Resiliency.WeightedSemaphore.acquire(MyApp.DbPool, 5, fn ->
  Repo.insert_all(Event, batch)
end)
```

Key traits:

- Adds latency only when the semaphore is saturated.
- Reduces load on the protected resource.
- Stateful -- requires a `GenServer`.
- Permits are auto-released on normal return, raise, exit, or throw -- no
  leaks.

---

### "I need to run tasks in parallel with richer semantics than Task"

Use **`Resiliency.TaskExtension`** -- stateless combinators for common
concurrency patterns.

**Race** -- first success wins, losers are killed:

```elixir
{:ok, fastest} = Resiliency.TaskExtension.race([
  fn -> fetch_from_region(:us_east) end,
  fn -> fetch_from_region(:eu_west) end
])
```

**Parallel map** -- bounded concurrency, cancels on first error:

```elixir
{:ok, pages} = Resiliency.TaskExtension.map(urls, &fetch/1, max_concurrency: 10)
```

**All settled** -- never short-circuits, collects every result:

```elixir
results = Resiliency.TaskExtension.all_settled([
  fn -> risky_a() end,
  fn -> risky_b() end
])
# => [{:ok, _}, {:error, _}]
```

**First ok** -- sequential fallback chain:

```elixir
{:ok, value} = Resiliency.TaskExtension.first_ok([
  fn -> check_l1_cache(key) end,
  fn -> check_l2_cache(key) end,
  fn -> query_database(key) end
])
```

Key traits:

- Stateless -- no process to start.
- Task crashes never crash the caller.
- Results are always in input order (for `map` and `all_settled`).

---

## Full Comparison Table

| Pattern | Problem | Adds Latency? | Adds Load? | Stateful? | Best For |
|---|---|---|---|---|---|
| `BackoffRetry` | Transient failures | Yes -- backoff delays between attempts | No -- sequential attempts | No | HTTP calls, database queries, anything with intermittent errors |
| `Hedged` | Tail latency | No -- reduces p99 | Yes -- fires extra requests | Adaptive: yes; Stateless: no | Latency-sensitive RPCs, fan-out queries, cache lookups |
| `SingleFlight` | Thundering herd / duplicate work | No -- late arrivals skip the I/O and share the result | No -- reduces load by deduplication | Yes | Cache population, config reloads, expensive computations with shared keys |
| `WeightedSemaphore` | Unbounded concurrency | When saturated -- callers queue | No -- caps it | Yes | Database pools, API rate limits, disk I/O, GPU access |
| `TaskExtension.race` | Need the fastest result from N sources | No -- returns the first success | Yes -- runs all concurrently | No | Multi-region fetch, redundant providers |
| `TaskExtension.map` | Parallel processing with a concurrency cap | No (unless saturated) | Bounded by `max_concurrency` | No | Bulk HTTP fetches, batch processing |
| `TaskExtension.all_settled` | Run all, tolerate individual failures | No | Yes -- runs all concurrently | No | Health checks, non-critical side effects, audit logging |
| `TaskExtension.first_ok` | Sequential fallback chain | Yes -- tries one at a time | No -- sequential | No | Cache/DB/API tiered lookups |

---

## "Why not just use..."

### `Task.async` + `Task.await`

`Task.await` crashes the caller on timeout or task failure.
`Resiliency.TaskExtension.race` and `all_settled` handle failures gracefully --
crashed tasks are skipped or returned as `{:error, reason}`, and the caller
never crashes.  `TaskExtension.map` also cancels remaining work on first error,
which `Task.async_stream` does not do.

### `GenServer.call` with a timeout

A `GenServer.call` timeout exits the caller but **does not** stop the server
from processing the request.  `Resiliency.WeightedSemaphore.acquire/4` supports
a caller-side timeout that returns `{:error, :timeout}` cleanly, and permits
are auto-released regardless of outcome.  `Resiliency.SingleFlight.flight/4`
similarly supports a timeout -- the in-flight function continues for other
waiters, but your caller gets an exit it can catch.

### `Process.send_after` / `:timer.sleep` for retry

Rolling your own retry loop with `Process.send_after` or `:timer.sleep` means
reimplementing backoff strategies, attempt counting, budgets, abort semantics,
and `on_retry` callbacks.  `Resiliency.BackoffRetry.retry/2` handles all of
this in a single function call with composable, stream-based backoff.  It also
supports `reraise: true` to preserve the original stacktrace -- something a
hand-rolled loop typically drops.

### Raw `Task.async_stream` for parallel work

`Task.async_stream` returns a lazy stream, requires you to handle `:exit`
tuples yourself, and does not cancel remaining work on failure.
`Resiliency.TaskExtension.map/3` returns `{:ok, results}` or
`{:error, reason}`, cancels all in-flight tasks on the first failure, and
preserves input order.  If you need all results regardless of failure, use
`all_settled` instead.

### Spawning two tasks manually for hedging

Manually spawning a primary and a backup task, selecting the first result, and
killing the loser is roughly what `Resiliency.Hedged` does -- but adaptive
hedging also tracks latency percentiles and uses a token bucket to avoid
stampeding the backend when it is already slow.  The stateless mode is a
drop-in replacement for the manual approach with cleaner semantics.

---

## When to Combine Patterns

Patterns in this library compose naturally.  Here are common combinations.

### Retry + Hedge

Retry handles **total failures**; hedging handles **slow responses**.  Use
retry as the outer wrapper when the entire hedged call might fail:

```elixir
Resiliency.BackoffRetry.retry(
  fn ->
    Resiliency.Hedged.run(MyHedge, fn -> HttpClient.get!(url) end)
  end,
  max_attempts: 3,
  backoff: :exponential
)
```

The hedge reduces tail latency on each individual attempt, and the retry
recovers from complete failures across attempts.

### Hedge + Semaphore

Hedging adds load.  If the downstream service has limited capacity, wrap the
hedged function body in a semaphore to cap total concurrent requests:

```elixir
Resiliency.Hedged.run(MyHedge, fn ->
  Resiliency.WeightedSemaphore.acquire(MyApp.ApiLimit, 1, fn ->
    HttpClient.get!(url)
  end)
end)
```

This way, even if multiple hedges fire concurrently, total concurrency against
the backend stays bounded.

### SingleFlight + Retry

Deduplicate first, then retry inside the flight function.  This way N callers
still collapse into one execution, and that one execution gets retry semantics:

```elixir
Resiliency.SingleFlight.flight(MyFlights, cache_key, fn ->
  Resiliency.BackoffRetry.retry(fn ->
    ExpensiveService.fetch(cache_key)
  end, max_attempts: 3)
end)
```

Placing retry **outside** SingleFlight would defeat deduplication -- each retry
attempt would be a separate flight.

### SingleFlight + Semaphore

When you have many distinct keys but still want to bound total concurrency
across all of them:

```elixir
Resiliency.SingleFlight.flight(MyFlights, key, fn ->
  Resiliency.WeightedSemaphore.acquire(MyApp.DbPool, 1, fn ->
    Repo.get!(Resource, key)
  end)
end)
```

---

## Parameter Quick-Reference

### `Resiliency.BackoffRetry.retry/2`

| Option | Type | Default | Recommendation |
|---|---|---|---|
| `:backoff` | `:exponential`, `:linear`, `:constant`, or `Enumerable` | `:exponential` | Use `:exponential` for most network calls; `:constant` for polling loops |
| `:base_delay` | ms | `100` | Match to the downstream service's typical recovery time |
| `:max_delay` | ms | `5_000` | Cap at a value that keeps total retry time within your SLA |
| `:max_attempts` | positive integer | `3` | 3--5 for transient errors; 1 to disable retries |
| `:budget` | ms or `:infinity` | `:infinity` | Set to your overall timeout to avoid retrying past a deadline |
| `:retry_if` | `fn {:error, reason} -> boolean` | retries all errors | Always set this -- retry only transient/retriable errors |
| `:on_retry` | `fn attempt, delay, error -> any` | `nil` | Use for logging or metrics |
| `:sleep_fn` | `fn ms -> any` | `Process.sleep/1` | Inject a no-op for tests |
| `:reraise` | boolean | `false` | Set `true` if you want exceptions to propagate with their original stacktrace |

### `Resiliency.Hedged.run/2` (stateless)

| Option | Type | Default | Recommendation |
|---|---|---|---|
| `:delay` | ms | `100` | Set to your p50--p95 latency; too low wastes requests, too high defeats the purpose |
| `:max_requests` | positive integer | `2` | 2 is usually enough; 3 for very high-value calls |
| `:timeout` | ms | `5_000` | Set to your overall deadline |
| `:non_fatal` | `fn reason -> boolean` | `fn _ -> false end` | Return `true` for errors that should immediately trigger the next hedge |
| `:on_hedge` | `fn attempt -> any` | `nil` | Use for metrics -- track how often hedges fire |

### `Resiliency.Hedged.start_link/1` (adaptive tracker)

| Option | Type | Default | Recommendation |
|---|---|---|---|
| `:name` | atom or `{:via, ...}` | required | One tracker per logical operation type |
| `:percentile` | number | `95` | 95 is a good default; use 99 for ultra-low-latency paths |
| `:buffer_size` | positive integer | `1_000` | Increase if your traffic is very bursty |
| `:min_delay` | ms | `1` | Raise if you want a floor to avoid sub-millisecond hedges |
| `:max_delay` | ms | `5_000` | Match to your timeout |
| `:initial_delay` | ms | `100` | Used before enough samples are collected |
| `:min_samples` | non-negative integer | `10` | Lower for faster adaptation; higher for more stability |
| `:token_max` | number | `10` | Controls hedge budget -- lower values hedge less often |
| `:token_success_credit` | number | `0.1` | Each successful request adds this many tokens |
| `:token_hedge_cost` | number | `1.0` | Each hedge spends this many tokens |
| `:token_threshold` | number | `1.0` | Hedging is suppressed below this token level |

### `Resiliency.SingleFlight.flight/3,4`

| Option | Type | Default | Recommendation |
|---|---|---|---|
| `server` | name or PID | required | One server per deduplication domain |
| `key` | any term | required | Use a string or tuple that uniquely identifies the work |
| `timeout` (4-arity) | ms or `:infinity` | `:infinity` | Set to your caller's deadline -- the in-flight function keeps running for other waiters |

`Resiliency.SingleFlight.forget/2` evicts a key so the next call triggers a
fresh execution -- useful after a known data change.

### `Resiliency.WeightedSemaphore`

| Option | Type | Default | Recommendation |
|---|---|---|---|
| `:name` | atom or `{:via, ...}` | required | One semaphore per protected resource |
| `:max` | positive integer | required | Set to the resource's actual concurrency limit |
| `weight` (in `acquire/3,4`) | positive integer | `1` | Model the relative cost of each operation |
| `timeout` (in `acquire/4`) | ms or `:infinity` | `:infinity` | Set to avoid unbounded queue waits under load |

`try_acquire/2,3` returns `:rejected` immediately if permits are unavailable --
use it for best-effort work that can be dropped.

### `Resiliency.TaskExtension`

| Function | Key Options | Defaults | Notes |
|---|---|---|---|
| `race/2` | `timeout` | `:infinity` | First success wins; all failures yield `{:error, :all_failed}` |
| `all_settled/2` | `timeout` | `:infinity` | Timed-out tasks get `{:error, :timeout}` in the result list |
| `map/3` | `max_concurrency`, `timeout` | `System.schedulers_online()`, `:infinity` | Cancels everything on first failure |
| `first_ok/2` | `timeout` | `:infinity` | Sequential -- total timeout spans all attempts |
