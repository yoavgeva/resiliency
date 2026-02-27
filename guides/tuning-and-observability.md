# Tuning and Observability

This guide covers parameter selection, tuning strategies, and observability
patterns for every module in the Resiliency library. Each section provides a
parameter reference table, explains how parameters interact, and gives concrete
recommendations for common workloads.

---

## Table of Contents

1. [CircuitBreaker Tuning](#circuitbreaker-tuning)
2. [BackoffRetry Tuning](#backoffretry-tuning)
3. [Hedged Requests Tuning](#hedged-requests-tuning)
4. [SingleFlight Tuning](#singleflight-tuning)
5. [Task Combinator Tuning](#task-combinator-tuning)
6. [WeightedSemaphore Tuning](#weightedsemaphore-tuning)
7. [Observability](#observability)
8. [Common Pitfalls](#common-pitfalls)

---

## CircuitBreaker Tuning

### Parameter Reference

| Parameter | Default | Range | Effect |
|---|---|---|---|
| `:name` | -- (required) | atom or `{:via, ...}` | Registered name for the GenServer. |
| `:window_size` | `100` | `1..` | Number of call outcomes in the count-based sliding window. Larger windows smooth out short bursts but react slower to genuine shifts. |
| `:failure_rate_threshold` | `0.5` | `0.0..1.0` | Failure rate that trips the circuit. `0.5` means the circuit trips when half or more of the recorded calls fail. |
| `:slow_call_threshold` | `:infinity` | `:infinity` or `1..` ms | Duration above which a call is classified as "slow". `:infinity` disables slow call detection entirely. |
| `:slow_call_rate_threshold` | `1.0` | `0.0..1.0` | Slow call rate that trips the circuit. `1.0` effectively disables slow-rate tripping. |
| `:open_timeout` | `60_000` ms | `1..` | Time the circuit stays `:open` before transitioning to `:half_open` for probing. |
| `:permitted_calls_in_half_open` | `1` | `1..` | Number of probe calls allowed through in `:half_open` state before deciding to close or reopen. |
| `:minimum_calls` | `10` | `1..` | Minimum recorded calls in the window before the failure rate is evaluated. Prevents tripping on small sample sizes. |
| `:should_record` | default predicate | `fn result -> :success \| :failure \| :ignore` | Custom classification function. `:ignore` results are not counted in the window. |
| `:on_state_change` | `nil` | `fn name, from, to -> any` or `nil` | Callback fired on every state transition. Use for logging, metrics, or telemetry. |

### How Parameters Interact

The circuit evaluates after each recorded call:

```
if window.total >= minimum_calls do
  if failure_rate >= failure_rate_threshold or slow_rate >= slow_call_rate_threshold do
    trip to :open
  end
end
```

The `:minimum_calls` parameter acts as a warm-up guard -- the circuit will not
trip until enough calls have been observed. This prevents a single failure from
tripping a freshly started breaker.

The sliding window is count-based (not time-based). Old outcomes are evicted
when new ones push them out of the fixed-size buffer. This means the window
naturally adapts to traffic volume without requiring time-based expiry.

### Tuning for Common Workloads

| Scenario | `failure_rate_threshold` | `minimum_calls` | `window_size` | `open_timeout` | Notes |
|---|---|---|---|---|---|
| High-throughput API | `0.5` | `20` | `200` | `30_000` | Larger window for stable signal. |
| Critical payment service | `0.3` | `10` | `100` | `60_000` | Trip earlier to protect revenue. |
| Background job queue | `0.8` | `50` | `500` | `120_000` | Tolerate more failures, longer recovery. |
| Health-check probe | `0.5` | `3` | `10` | `10_000` | Small window, fast recovery for probes. |
| Slow-call-sensitive API | `0.5` / `0.3` (slow) | `10` | `100` | `30_000` | Set `slow_call_threshold` to p99 latency. |

### Interpreting get_stats

Call `Resiliency.CircuitBreaker.get_stats/1` to inspect the breaker at runtime:

```elixir
%{
  state: :closed,
  total: 87,
  failures: 12,
  slow_calls: 3,
  failure_rate: 0.1379,
  slow_call_rate: 0.0345
}
```

| Stat | Healthy range | What it means |
|---|---|---|
| `failure_rate` | < `failure_rate_threshold` | Current failure rate in the sliding window. |
| `slow_call_rate` | < `slow_call_rate_threshold` | Current slow call rate. High values suggest downstream latency issues. |
| `total` | >= `minimum_calls` | Total calls in the window. Below `minimum_calls`, the circuit will not trip. |
| `state` | `:closed` | Current state. `:open` means rejecting calls; `:half_open` means probing. |

---

## BackoffRetry Tuning

### Parameter Reference

| Parameter | Default | Range | Effect |
|---|---|---|---|
| `:max_attempts` | `3` | `1..` | Total attempts including the first call. `1` means no retries. |
| `:backoff` | `:exponential` | `:exponential`, `:linear`, `:constant`, or any `Enumerable` of ms | Determines the shape of the delay curve between retries. |
| `:base_delay` | `100` ms | `0..` | Seed value for delay computation -- first retry waits this long (before cap/jitter). |
| `:max_delay` | `5_000` ms | `0..` | Hard ceiling on any single retry delay. Applied via `Backoff.cap/2`. |
| `:budget` | `:infinity` | `:infinity` or `0..` ms | Total wall-clock budget for all attempts. When the next delay would push past the deadline, retries stop. |
| `:retry_if` | `fn {:error, _} -> true end` | `fn result -> boolean end` | Predicate that decides whether a given failure is retryable. Non-matching errors are returned immediately. |
| `:on_retry` | `nil` | `fn attempt, delay, error -> any` | Callback fired before each sleep. Use for logging, metrics, telemetry. |
| `:sleep_fn` | `&Process.sleep/1` | `fn ms -> any` | Injectable sleep -- replace with a no-op or test double in tests. |
| `:reraise` | `false` | `true`, `false` | When `true`, re-raises rescued exceptions (with original stacktrace) instead of returning `{:error, exception}` after exhausting retries. |

### How Parameters Interact

The effective retry sequence is computed as:

```
delays = backoff_strategy(base_delay)
         |> Backoff.cap(max_delay)
         |> Enum.take(max_attempts - 1)
```

For exponential backoff with the defaults, the delay sequence before cap is:

```
attempt 1: immediate (no delay -- first call)
attempt 2: 100 ms
attempt 3: 200 ms
```

With `max_attempts: 5` and `base_delay: 100`:

```
attempt 1: immediate
attempt 2: 100 ms
attempt 3: 200 ms
attempt 4: 400 ms
attempt 5: 800 ms
```

The `:budget` option acts as a secondary stop condition. Even if `max_attempts`
has not been reached, the retry loop aborts when the next sleep would exceed
the total time budget. This makes `:budget` the right knob for SLA-sensitive
callers -- set it to your upstream timeout minus a safety margin.

The `Backoff.jitter/2` modifier (usable when passing a custom stream) spreads
each delay `d` uniformly over `[d * (1 - proportion), d * (1 + proportion)]`.
Jitter is critical in multi-instance deployments to avoid thundering herd on
the downstream service after a shared failure.

### Backoff Strategy Formulas

| Strategy | Formula (n-th retry, 0-indexed) | Sequence (base=100) |
|---|---|---|
| `:exponential` | `base * multiplier^n` | 100, 200, 400, 800, 1600, ... |
| `:linear` | `base + increment * n` | 100, 200, 300, 400, 500, ... |
| `:constant` | `base` | 100, 100, 100, 100, 100, ... |

### Tuning for Common Workloads

| Scenario | `max_attempts` | `backoff` | `base_delay` | `max_delay` | `budget` | Notes |
|---|---|---|---|---|---|---|
| Low-latency API | 2--3 | `:exponential` | 50 | 500 | 1_000 | Short budget prevents blocking the request path. |
| Batch / ETL job | 5--8 | `:exponential` | 500 | 30_000 | `:infinity` | Generous delays -- throughput matters more than latency. |
| Database reconnect | 10+ | `:exponential` + jitter | 200 | 60_000 | `:infinity` | Long max_delay with jitter to avoid connection storms. |
| Idempotent webhook | 4 | `:linear` | 1_000 | 10_000 | 30_000 | Linear ramp gives the receiver steady recovery time. |
| Circuit-breaker probe | 1 | `:constant` | 0 | 0 | 500 | Single attempt with tight budget -- just checking if the service is back. |

### Custom Backoff Streams

For advanced scenarios, compose your own stream with jitter and cap:

```elixir
custom_backoff =
  Resiliency.BackoffRetry.Backoff.exponential(base: 200, multiplier: 3)
  |> Resiliency.BackoffRetry.Backoff.jitter(0.25)
  |> Resiliency.BackoffRetry.Backoff.cap(15_000)

Resiliency.BackoffRetry.retry(fn -> call_service() end,
  backoff: custom_backoff,
  max_attempts: 6
)
```

Or pass a literal list when you want fully deterministic delays:

```elixir
Resiliency.BackoffRetry.retry(fn -> call_service() end,
  backoff: [100, 500, 2_000, 5_000]
)
```

When a list is provided, `max_attempts` is implicitly `length(list) + 1` (one
initial call plus one retry per delay entry).

### Rule of Thumb

> **Total worst-case latency** = `sum(delays) + max_attempts * max_call_duration`.
> If this exceeds your caller's timeout, either reduce `max_attempts`, lower
> `max_delay`, or set a `:budget`.

---

## Hedged Requests Tuning

### Stateless Mode Parameter Reference

| Parameter | Default | Range | Effect |
|---|---|---|---|
| `:delay` | `100` ms | `0..` | Time to wait before firing the backup (hedge) request. |
| `:max_requests` | `2` | `1..` | Total concurrent attempts. `1` disables hedging entirely. |
| `:timeout` | `5_000` ms | `1..` | Overall deadline -- all in-flight tasks are killed at this point. |
| `:non_fatal` | `fn _ -> false end` | `fn reason -> boolean` | When `true` for a failure reason, the next hedge fires immediately instead of waiting for the delay. |
| `:on_hedge` | `nil` | `fn attempt -> any` | Callback invoked before each hedge fires. Use for metrics and logging. |

### Adaptive Mode (Tracker) Parameter Reference

When using `Resiliency.Hedged.start_link/1`, the delay auto-tunes based on
observed latency. A token bucket throttles the hedge rate under load.

| Parameter | Default | Range | Effect |
|---|---|---|---|
| `:name` | -- (required) | atom or `{:via, ...}` | Registered name for the tracker GenServer. |
| `:percentile` | `95` | `0..100` | Target latency percentile used as the adaptive delay. Higher values hedge less aggressively. |
| `:buffer_size` | `1_000` | `1..` | Number of latency samples in the rolling window. Larger buffers smooth out spikes but react slower to shifts. |
| `:min_delay` | `1` ms | `0..` | Floor for the adaptive delay. Prevents hedging on every request even when p95 is near zero. |
| `:max_delay` | `5_000` ms | `1..` | Ceiling for the adaptive delay. Ensures hedges still fire even during latency spikes. |
| `:initial_delay` | `100` ms | `0..` | Delay used during cold-start before `:min_samples` observations are collected. |
| `:min_samples` | `10` | `0..` | Number of observations required before switching from `:initial_delay` to the adaptive percentile. |
| `:token_max` | `10` | `> 0` | Token bucket capacity. Determines burst budget for hedging. |
| `:token_success_credit` | `0.1` | `> 0` | Tokens earned per completed request (hedged or not). |
| `:token_hedge_cost` | `1.0` | `> 0` | Tokens consumed when a hedge fires. |
| `:token_threshold` | `1.0` | `>= 0` | Minimum token balance required to allow hedging. Below this, `max_requests` is forced to `1`. |

### How Adaptive Delay Works

1. **Cold start** -- Before `min_samples` observations, the tracker returns
   `initial_delay` as the hedge delay. Pick this conservatively -- too low and
   you double load during startup.

2. **Steady state** -- The tracker maintains a circular buffer of the last
   `buffer_size` latency samples. On each `get_config/1` call, it computes the
   configured percentile of the buffer and clamps it to `[min_delay, max_delay]`.
   This becomes the hedge delay.

3. **Token bucket** -- Every completed request (success or failure) adds
   `token_success_credit` tokens. Every hedge that fires costs `token_hedge_cost`
   tokens. When tokens drop below `token_threshold`, hedging is disabled until
   enough successful requests replenish the bucket. This creates a natural
   feedback loop: under sustained load where hedges are not winning, the system
   backs off automatically.

**Effective hedge rate** (steady state):

```
max_hedge_fraction = token_success_credit / token_hedge_cost
```

With defaults (0.1 / 1.0), at most 10% of requests will be hedged in steady
state. To allow up to 20%, set `token_success_credit: 0.2`. To allow up to
5%, set `token_success_credit: 0.05` or `token_hedge_cost: 2.0`.

### Tuning for Different Scenarios

| Scenario | `:percentile` | `:buffer_size` | Token settings | Notes |
|---|---|---|---|---|
| Fast API (p50 ~5ms) | `90` | `500` | defaults | Aggressive hedging -- low cost per extra request. |
| Slow DB query (p50 ~200ms) | `99` | `2_000` | `token_success_credit: 0.05` | Conservative -- extra DB queries are expensive. |
| Multi-region fanout | `95` | `1_000` | defaults | Classic tail-latency use case. |
| Startup / cold cache | -- | -- | `initial_delay: 500` | High initial delay avoids flooding a cold service. |

### Interpreting Tracker Stats

Call `Resiliency.Hedged.Tracker.stats/1` to inspect the tracker at runtime:

```elixir
%{
  total_requests: 15234,
  hedged_requests: 1412,
  hedge_won: 987,
  p50: 12,
  p95: 45,
  p99: 210,
  current_delay: 45,
  tokens: 7.2
}
```

| Stat | Healthy range | What it means |
|---|---|---|
| `hedged_requests / total_requests` | 5--15% | Hedge rate. Below 5% suggests the delay is too high or the service is healthy (good). Above 20% means you are generating significant extra load. |
| `hedge_won / hedged_requests` | 30--70% | Win rate. Below 30% means hedges rarely help -- consider raising the percentile. Above 70% means the primary is consistently slow -- investigate the downstream. |
| `tokens` | `> token_threshold` | Token balance. If consistently near zero, hedging is being throttled. Raise `token_success_credit` or lower `token_hedge_cost` if you want more hedging. |
| `p99 / p50` ratio | < 10x | Tail-to-median ratio. A high ratio (> 20x) indicates severe tail latency -- hedging is valuable here. |
| `current_delay` | between `min_delay` and `max_delay` | The adaptive delay. If pinned at `max_delay`, latency has spiked and the tracker is being conservative. |

---

## SingleFlight Tuning

`Resiliency.SingleFlight` has no tunable numeric parameters -- its behavior is
determined entirely by key design and usage patterns.

### When It Helps

- **Cache stampede** -- Many processes request the same cache key after expiry.
  Without SingleFlight, all of them hit the database. With it, one process
  fetches while the rest share the result.

- **Expensive computation** -- Deduplicating concurrent calls to a heavy
  aggregation or report-generation function.

- **External API rate limits** -- Preventing duplicate requests to a
  rate-limited third-party service.

### When It Hurts

- **Non-idempotent operations** -- If the function has side effects that must
  execute per-caller (e.g., incrementing a counter, sending a notification),
  SingleFlight will suppress those side effects for coalesced callers.

- **Caller-specific context** -- If each caller needs a slightly different
  variant of the result (different query parameters, different auth tokens),
  deduplication by a shared key will return the wrong result for some callers.

- **Very short functions** -- If the function completes in microseconds, the
  overhead of the GenServer round-trip (message passing, ETS or map lookup) may
  exceed the savings from deduplication.

### Key Design Considerations

| Consideration | Guidance |
|---|---|
| Key granularity | Too broad (e.g., `"users"`) coalesces unrelated calls. Too narrow (e.g., `"user:#{id}:#{timestamp}"`) defeats deduplication. Use the natural cache key. |
| Key type | Any Erlang term works. Atoms and short strings are fastest for map lookups. |
| Error propagation | If the executing function fails, **all** waiting callers receive the same `{:error, reason}`. This is usually correct for cache-fill scenarios but may not be appropriate if different callers should retry independently. |
| Timeout | Use `flight/4` with a timeout when the function may be slow. Timed-out callers exit, but the in-flight function continues and serves other waiters. |
| `forget/2` | Call `forget/2` to force a fresh execution for the next caller. Useful when you know cached data is stale (e.g., after a write). Existing waiters still receive the original result. |

---

## Task Combinator Tuning

### Choosing the Right Combinator

| Module | Use when | Concurrency | Failure behavior |
|---|---|---|---|
| `Resiliency.Race` | You need the fastest result from N alternatives | All functions run concurrently | First success wins; crashed tasks are skipped; returns `{:error, :all_failed}` if all fail |
| `Resiliency.AllSettled` | You need every result regardless of failures | All functions run concurrently | Each result is `{:ok, _}` or `{:error, _}` independently |
| `Resiliency.Map` | You are processing a collection with bounded parallelism | Up to `max_concurrency` at a time | Cancels all remaining work on first failure |
| `Resiliency.FirstOk` | You have a fallback chain (cache -> DB -> API) | Sequential -- one at a time | Tries the next function only after the previous one fails |

### Timeout Selection

| Parameter | Default | Range | Effect |
|---|---|---|---|
| `:timeout` (Race) | `:infinity` | `:infinity` or `1..` ms | Overall deadline for the race. Remaining tasks are killed when it expires. |
| `:timeout` (AllSettled) | `:infinity` | `:infinity` or `1..` ms | Completed tasks keep their results; tasks still running get `{:error, :timeout}`. |
| `:timeout` (Map) | `:infinity` | `:infinity` or `1..` ms | Returns `{:error, :timeout}` and kills all active tasks. |
| `:timeout` (FirstOk) | `:infinity` | `:infinity` or `1..` ms | Total budget across all sequential attempts. |
| `:max_concurrency` (Map) | `System.schedulers_online()` | `1..` | Limits how many items are processed in parallel. |

### Timeout Rules of Thumb

- For `Race.run/1` -- set the timeout to your **SLA ceiling**. If no backend
  responds in time, you want a clear timeout rather than an indefinite hang.

- For `AllSettled.run/1` -- set the timeout to the **slowest acceptable task
  duration**. Tasks that finish within the deadline keep their results; the
  rest are marked as timed out.

- For `Resiliency.Map.run/2` -- multiply your **per-item budget** by the number of items
  divided by `max_concurrency`, then add a margin. Or use `:infinity` and rely
  on per-item timeouts inside the function.

- For `FirstOk.run/1` -- set the timeout to the **total latency budget** for the
  entire fallback chain. Each attempt subtracts from the remaining budget.

### `Race` vs `FirstOk` Decision

```
Do you want concurrent execution?
  Yes -> Race.run/1 (all functions run at once, first success wins)
  No  -> FirstOk.run/1 (sequential, stops at first success)
```

Use `Race.run/1` when all backends can handle the load of concurrent requests. Use
`FirstOk.run/1` when you want to avoid unnecessary calls to slower/more expensive
backends.

---

## WeightedSemaphore Tuning

### Parameter Reference

| Parameter | Default | Range | Effect |
|---|---|---|---|
| `:name` | -- (required) | atom or `{:via, ...}` | Registered name for the semaphore GenServer. |
| `:max` | -- (required) | `1..` | Total permit capacity. The sum of all concurrently held weights must not exceed this value. |

### `max` Selection

The `:max` value represents your concurrency budget. Choose it based on the
downstream resource's capacity:

| Resource | Suggested `max` | Rationale |
|---|---|---|
| Database connection pool (size N) | `N` or `N - 1` | Match the pool size. Reserve one connection for health checks if needed. |
| External API (rate limit R req/s) | `R / avg_requests_per_second` | Keep in-flight requests below the rate limit. |
| CPU-bound work | `System.schedulers_online()` | One permit per scheduler avoids over-subscription. |
| Memory-bound work | `available_mb / per_task_mb` | Weight by memory cost per task. |

### Weight Assignment Strategies

| Strategy | When to use | Example |
|---|---|---|
| Uniform (weight=1) | All operations have equal cost | `acquire(sem, fn -> read_row() end)` |
| Cost-proportional | Operations vary in resource consumption | `acquire(sem, row_count, fn -> bulk_insert(rows) end)` |
| Tiered | Two or three operation classes | Reads = 1, writes = 3, bulk = 10 |
| Estimated | Cost is data-dependent | `acquire(sem, estimate_cost(query), fn -> run(query) end)` |

### Backpressure Behavior

The semaphore's FIFO queue provides natural backpressure:

- **Blocking** -- `acquire/3` blocks the caller until permits are available.
  This is the default and simplest mode. Callers queue up and are served in
  order.

- **Non-blocking** -- `try_acquire/3` returns `:rejected` immediately if
  permits are not available or if there are waiters in the queue. Use this for
  "best effort" work that can be dropped under load.

- **Timeout** -- `acquire/4` accepts a timeout in milliseconds. If permits are
  not available within the deadline, returns `{:error, :timeout}`. The caller
  is removed from the queue.

**Fairness guarantee** -- Waiters are served in strict FIFO order. A large
waiter at the head of the queue blocks smaller waiters behind it, preventing
starvation. This means a weight-8 request waiting for permits will not be
bypassed by a weight-1 request, even if capacity exists for the smaller
request.

### Sizing Guidelines

```
Utilization = avg_concurrent_weight / max
```

- **< 50%** -- The semaphore is rarely contended. You may be over-provisioned,
  or the workload is bursty. Consider lowering `max` to catch genuine overload
  earlier.

- **50--80%** -- Healthy range. Some queuing occurs during bursts but callers
  are not waiting long.

- **> 90%** -- The semaphore is a bottleneck. Callers are frequently blocked.
  Either increase `max` (if the downstream can handle it) or reduce the arrival
  rate.

---

## Observability

### Emitting Telemetry from CircuitBreaker

Use the `:on_state_change` callback to emit `:telemetry` events on every
state transition:

```elixir
{Resiliency.CircuitBreaker,
 name: MyApp.Breaker,
 failure_rate_threshold: 0.5,
 on_state_change: fn name, from, to ->
   :telemetry.execute(
     [:my_app, :circuit_breaker, :state_change],
     %{},
     %{name: name, from: from, to: to}
   )
 end}
```

Poll `Resiliency.CircuitBreaker.get_stats/1` periodically for dashboard metrics:

```elixir
stats = Resiliency.CircuitBreaker.get_stats(MyApp.Breaker)

:telemetry.execute(
  [:my_app, :circuit_breaker, :stats],
  %{
    failure_rate: stats.failure_rate,
    slow_call_rate: stats.slow_call_rate,
    total: stats.total,
    failures: stats.failures
  },
  %{name: MyApp.Breaker, state: stats.state}
)
```

### Logging Retry Attempts

Use the `:on_retry` callback to emit structured log lines on every retry:

```elixir
require Logger

Resiliency.BackoffRetry.retry(
  fn -> MyService.call(params) end,
  max_attempts: 4,
  backoff: :exponential,
  base_delay: 200,
  on_retry: fn attempt, delay, error ->
    Logger.warning(
      "Retry attempt",
      attempt: attempt,
      delay_ms: delay,
      error: inspect(error),
      service: "my_service"
    )
  end
)
```

### Emitting Telemetry from BackoffRetry

Wrap your retry call to emit `:telemetry` events for each attempt and for the
final outcome:

```elixir
defmodule MyApp.Resilient do
  def call_with_telemetry(fun, opts \\ []) do
    start_time = System.monotonic_time()
    meta = %{service: Keyword.get(opts, :service, :unknown)}

    result =
      Resiliency.BackoffRetry.retry(fun,
        max_attempts: Keyword.get(opts, :max_attempts, 3),
        on_retry: fn attempt, delay, error ->
          :telemetry.execute(
            [:my_app, :retry, :attempt],
            %{delay_ms: delay},
            Map.merge(meta, %{attempt: attempt, error: inspect(error)})
          )
        end,
        retry_if: Keyword.get(opts, :retry_if, fn {:error, _} -> true end)
      )

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, _} ->
        :telemetry.execute(
          [:my_app, :retry, :success],
          %{duration: duration},
          meta
        )

      {:error, _} ->
        :telemetry.execute(
          [:my_app, :retry, :failure],
          %{duration: duration},
          meta
        )
    end

    result
  end
end
```

### Emitting Telemetry from Hedged Requests

Use `:on_hedge` for per-hedge telemetry, and wrap the call for overall metrics:

```elixir
defmodule MyApp.HedgedCall do
  def run(fun, opts \\ []) do
    service = Keyword.get(opts, :service, :unknown)
    start_time = System.monotonic_time()

    result =
      Resiliency.Hedged.run(fun,
        delay: Keyword.get(opts, :delay, 100),
        timeout: Keyword.get(opts, :timeout, 5_000),
        on_hedge: fn attempt ->
          :telemetry.execute(
            [:my_app, :hedged, :hedge_fired],
            %{},
            %{service: service, attempt: attempt}
          )
        end
      )

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, _} ->
        :telemetry.execute(
          [:my_app, :hedged, :success],
          %{duration: duration},
          %{service: service}
        )

      {:error, _} ->
        :telemetry.execute(
          [:my_app, :hedged, :failure],
          %{duration: duration},
          %{service: service}
        )
    end

    result
  end
end
```

### Monitoring Adaptive Hedging with Tracker.stats/1

Poll `Resiliency.Hedged.Tracker.stats/1` periodically to feed dashboards:

```elixir
defmodule MyApp.HedgeReporter do
  use GenServer

  def start_link(opts) do
    tracker = Keyword.fetch!(opts, :tracker)
    interval = Keyword.get(opts, :interval, 10_000)
    GenServer.start_link(__MODULE__, %{tracker: tracker, interval: interval})
  end

  @impl true
  def init(state) do
    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:report, state) do
    stats = Resiliency.Hedged.Tracker.stats(state.tracker)

    :telemetry.execute(
      [:my_app, :hedged, :tracker_stats],
      %{
        p50: stats.p50 || 0,
        p95: stats.p95 || 0,
        p99: stats.p99 || 0,
        current_delay: stats.current_delay,
        tokens: stats.tokens,
        total_requests: stats.total_requests,
        hedged_requests: stats.hedged_requests,
        hedge_won: stats.hedge_won
      },
      %{tracker: state.tracker}
    )

    hedge_rate =
      if stats.total_requests > 0,
        do: stats.hedged_requests / stats.total_requests,
        else: 0.0

    win_rate =
      if stats.hedged_requests > 0,
        do: stats.hedge_won / stats.hedged_requests,
        else: 0.0

    :telemetry.execute(
      [:my_app, :hedged, :tracker_rates],
      %{hedge_rate: hedge_rate, win_rate: win_rate},
      %{tracker: state.tracker}
    )

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :report, interval)
end
```

### Monitoring WeightedSemaphore

The semaphore does not expose internal stats directly. Instrument it by
wrapping calls:

```elixir
defmodule MyApp.InstrumentedSemaphore do
  def acquire(sem, weight, fun) do
    start_time = System.monotonic_time()

    result = Resiliency.WeightedSemaphore.acquire(sem, weight, fn ->
      wait_duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:my_app, :semaphore, :acquired],
        %{wait_duration: wait_duration, weight: weight},
        %{semaphore: sem}
      )

      fun.()
    end)

    total_duration = System.monotonic_time() - start_time

    case result do
      {:ok, _} ->
        :telemetry.execute(
          [:my_app, :semaphore, :complete],
          %{duration: total_duration, weight: weight},
          %{semaphore: sem, outcome: :ok}
        )

      {:error, _} ->
        :telemetry.execute(
          [:my_app, :semaphore, :complete],
          %{duration: total_duration, weight: weight},
          %{semaphore: sem, outcome: :error}
        )
    end

    result
  end

  def try_acquire(sem, weight, fun) do
    case Resiliency.WeightedSemaphore.try_acquire(sem, weight, fun) do
      :rejected ->
        :telemetry.execute(
          [:my_app, :semaphore, :rejected],
          %{weight: weight},
          %{semaphore: sem}
        )

        :rejected

      other ->
        other
    end
  end
end
```

### Suggested Telemetry Event Names

| Module | Event | Measurements | Metadata |
|---|---|---|---|
| CircuitBreaker | `[:app, :circuit_breaker, :state_change]` | `%{}` | `%{name: atom, from: atom, to: atom}` |
| CircuitBreaker | `[:app, :circuit_breaker, :stats]` | `%{failure_rate: float, total: integer, ...}` | `%{name: atom, state: atom}` |
| BackoffRetry | `[:app, :retry, :attempt]` | `%{delay_ms: integer}` | `%{attempt: integer, error: string, service: atom}` |
| BackoffRetry | `[:app, :retry, :success]` | `%{duration: native_time}` | `%{service: atom}` |
| BackoffRetry | `[:app, :retry, :failure]` | `%{duration: native_time}` | `%{service: atom}` |
| Hedged | `[:app, :hedged, :hedge_fired]` | `%{}` | `%{service: atom, attempt: integer}` |
| Hedged | `[:app, :hedged, :success]` | `%{duration: native_time}` | `%{service: atom}` |
| Hedged | `[:app, :hedged, :tracker_stats]` | `%{p50: num, p95: num, p99: num, ...}` | `%{tracker: atom}` |
| Semaphore | `[:app, :semaphore, :acquired]` | `%{wait_duration: native_time, weight: integer}` | `%{semaphore: atom}` |
| Semaphore | `[:app, :semaphore, :rejected]` | `%{weight: integer}` | `%{semaphore: atom}` |

---

## Common Pitfalls

| Mistake | Symptom | Fix |
|---|---|---|
| `minimum_calls` too low | Circuit trips on normal variance -- a few early failures trip the breaker. | Increase `minimum_calls` to at least 10. Higher for high-throughput services. |
| `failure_rate_threshold` too low | Circuit trips too aggressively; service appears degraded when it is merely imperfect. | Start with `0.5` and lower only if the downstream is critical and failures are costly. |
| `open_timeout` too short | Circuit keeps probing a still-broken service, consuming resources. | Set `open_timeout` to at least the downstream's expected recovery time. |
| `open_timeout` too long | Service has recovered but callers are still being rejected. | Balance between recovery time and responsiveness. Use `force_close/1` for manual intervention. |
| `window_size` too small | A few bad calls dominate the rate; circuit trips on transient spikes. | Use a window large enough to smooth out normal variance (e.g., 100+). |
| `permitted_calls_in_half_open` too low | A single unlucky probe reopens the circuit; recovery takes multiple open-timeout cycles. | Increase to 3--5 for more confident half-open evaluation. |
| Not handling `{:error, :circuit_open}` | Caller crashes or returns unexpected error shape. | Always pattern-match on `:circuit_open` and degrade gracefully. |
| Retry delay too short | Floods downstream during outage; downstream never recovers. | Increase `base_delay`, use exponential backoff, add jitter via `Backoff.jitter/2`. |
| No jitter on retries | Thundering herd -- all clients retry at the same instant. | Compose `Backoff.jitter(0.25)` into your backoff stream. |
| Retrying non-idempotent calls | Duplicate side effects (double charges, duplicate messages). | Use `:retry_if` to only retry safe errors (timeouts, connection refused). Return `Resiliency.BackoffRetry.abort(reason)` for fatal errors. |
| No `:budget` with high `max_attempts` | Callers block for minutes during sustained outages. | Set `:budget` to your SLA ceiling. |
| Hedge percentile too low (e.g., p50) | Every other request spawns a hedge -- doubles load on downstream. | Use p90--p99. Start with p95 and lower only if tail latency is severe and the downstream can handle it. |
| Hedge `initial_delay` too low | During cold start, hedges fire on nearly every request before samples accumulate. | Set `initial_delay` to your expected p95 or higher. |
| Token bucket too generous | Hedge rate exceeds expectations. | Lower `token_success_credit` or raise `token_hedge_cost`. The steady-state hedge fraction is `token_success_credit / token_hedge_cost`. |
| Token bucket too restrictive | Hedging is effectively disabled; tail latency suffers. | Raise `token_success_credit` or increase `token_max` for burst capacity. |
| SingleFlight key too broad | Unrelated requests share a result. | Use fine-grained keys that include all parameters affecting the result. |
| SingleFlight on non-idempotent work | Side effects (writes, increments) execute only once instead of per-caller. | Do not use SingleFlight for write operations. |
| Semaphore `max` too high | Downstream overloaded despite semaphore. | Lower `max` to match the downstream's actual capacity. |
| Semaphore `max` too low | Healthy throughput is artificially limited; callers queue unnecessarily. | Profile the downstream and raise `max` to its tested concurrency limit. |
| `try_acquire` without fallback | `:rejected` silently drops work. | Always handle the `:rejected` case -- return an error, queue the work, or degrade gracefully. |
| Weight exceeds max | `{:error, :weight_exceeds_max}` returned immediately. | Ensure no single operation's weight can exceed the semaphore's `:max`. Validate weights at the call site. |
| `Race.run/1` without timeout | If all backends hang, the caller hangs forever. | Always pass a `:timeout` to `Race.run/1` in production. |
| `Resiliency.Map.run/3` with `max_concurrency: 1` | Effectively sequential -- no parallelism benefit. | Use `max_concurrency` >= 2. If you need sequential execution, use `Enum.map/2` directly. |
| Forgetting to supervise stateful modules | Tracker, SingleFlight, or CircuitBreaker crashes and is not restarted. | Always start `Resiliency.CircuitBreaker`, `Resiliency.Hedged`, and `Resiliency.SingleFlight` under a supervisor using their `child_spec/1`. |
