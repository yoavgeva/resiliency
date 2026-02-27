# Getting Started

This guide walks you through the core modules in Resiliency with
real-world examples you can paste into an `iex` session or a Mix project.
By the end you will know how to retry flaky calls, hedge slow requests,
deduplicate concurrent work, race tasks, and rate-limit access to shared
resources.

## Installation

Add `resiliency` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:resiliency, "~> 0.1.0"}
  ]
end
```

Then fetch and compile:

```shell
mix deps.get
mix compile
```

Resiliency has zero runtime dependencies -- every module is self-contained
and ready to use without starting any extra applications.

---

## Your First Retry

`Resiliency.BackoffRetry` retries a function on failure with configurable
backoff. No macros, no processes -- just a function call.

### 1. Retry with defaults

The simplest form retries up to 3 times with exponential backoff
(100 ms, 200 ms, 400 ms):

```elixir
result =
  Resiliency.BackoffRetry.retry(fn ->
    case File.read("/tmp/config.json") do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :enoent}
    end
  end)

# After 3 failed attempts:
# => {:error, :enoent}
```

### 2. Customize the strategy

Imagine you are calling a flaky third-party API that occasionally returns
503. You want 5 attempts, linear backoff starting at 200 ms, and a cap of
2 seconds per delay:

```elixir
Resiliency.BackoffRetry.retry(
  fn ->
    # Simulate an HTTP call -- replace with your real client
    case :rand.uniform(3) do
      1 -> {:ok, %{status: 200, body: "OK"}}
      _ -> {:error, :service_unavailable}
    end
  end,
  max_attempts: 5,
  backoff: :linear,
  base_delay: 200,
  max_delay: 2_000
)
```

### 3. Filter which errors are retryable

Not every error deserves a retry. Use `:retry_if` to short-circuit on
permanent failures:

```elixir
Resiliency.BackoffRetry.retry(
  fn ->
    case :rand.uniform(4) do
      1 -> {:ok, "success"}
      2 -> {:error, :timeout}
      3 -> {:error, :econnrefused}
      4 -> {:error, :not_found}
    end
  end,
  max_attempts: 5,
  retry_if: fn
    {:error, :timeout} -> true
    {:error, :econnrefused} -> true
    _other -> false
  end
)
```

Here `:not_found` is treated as a permanent failure and returned
immediately without consuming additional attempts.

### 4. Abort early from inside the function

If the function itself discovers that retrying is pointless, wrap the
reason in `BackoffRetry.abort/1`:

```elixir
Resiliency.BackoffRetry.retry(
  fn ->
    case :rand.uniform(3) do
      1 -> {:ok, "payload"}
      2 -> {:error, :timeout}
      3 -> {:error, Resiliency.BackoffRetry.abort(:invalid_api_key)}
    end
  end,
  max_attempts: 10
)

# When abort is hit:
# => {:error, :invalid_api_key}
```

The abort stops retries immediately, regardless of remaining attempts or
the `:retry_if` predicate.

### 5. Add observability with `:on_retry`

Log every retry so you can correlate failures with your monitoring stack:

```elixir
require Logger

Resiliency.BackoffRetry.retry(
  fn ->
    case :rand.uniform(2) do
      1 -> {:ok, "data"}
      2 -> {:error, :timeout}
    end
  end,
  max_attempts: 4,
  backoff: :exponential,
  on_retry: fn attempt, delay_ms, error ->
    Logger.warning(
      "Retry attempt #{attempt}, sleeping #{delay_ms}ms after #{inspect(error)}"
    )
  end
)
```

### 6. Set a time budget

When you have a hard deadline -- say, an HTTP request timeout of 3
seconds -- use `:budget` to stop retrying once the budget is exhausted,
even if you have attempts left:

```elixir
Resiliency.BackoffRetry.retry(
  fn -> {:error, :timeout} end,
  max_attempts: 20,
  backoff: :constant,
  base_delay: 1_000,
  budget: 3_000
)
# Stops after ~3 seconds, not after 20 attempts
```

---

## Your First Hedged Request

`Resiliency.Hedged` fires a backup request after a delay and returns
whichever finishes first -- a technique from Google's "Tail at Scale"
paper for cutting tail latency. It supports two modes: stateless (fixed
delay) and stateful (adaptive, percentile-based delay).

### Stateless mode -- fixed delay

Use this when you know a reasonable delay up front, or when you do not
need adaptive tuning.

#### 1. Basic hedged call

Send a hedge after 150 ms. If the first request has not finished by then,
a second copy fires. The first success wins and the loser is cancelled:

```elixir
{:ok, body} =
  Resiliency.Hedged.run(
    fn ->
      # Simulate a database query with variable latency
      Process.sleep(Enum.random(50..300))
      {:ok, %{rows: [%{id: 1, name: "Alice"}]}}
    end,
    delay: 150,
    timeout: 5_000
  )
```

#### 2. Increase the fan-out

By default, at most 2 requests fly concurrently (the original plus one
hedge). Bump `:max_requests` to fan out further:

```elixir
{:ok, result} =
  Resiliency.Hedged.run(
    fn ->
      Process.sleep(Enum.random(10..500))
      {:ok, "response from replica"}
    end,
    delay: 100,
    max_requests: 3,
    timeout: 2_000
  )
```

### Stateful mode -- adaptive delay

In production, the right delay shifts as latency changes. Start a
`Resiliency.Hedged` tracker -- it records latencies and computes
the hedge delay as a percentile of observed values.

#### 1. Start the tracker

Add it to your supervision tree (or start it manually for experimentation):

```elixir
{:ok, _pid} =
  Resiliency.Hedged.start_link(
    name: MyApp.SearchHedge,
    percentile: 95,
    initial_delay: 100
  )
```

The tracker begins with an `initial_delay` of 100 ms and switches to
the observed p95 once it has collected enough samples.

#### 2. Run hedged calls through the tracker

Pass the tracker name as the first argument instead of options:

```elixir
{:ok, result} =
  Resiliency.Hedged.run(MyApp.SearchHedge, fn ->
    # Imagine this hits a search service with variable latency
    Process.sleep(Enum.random(20..200))
    {:ok, [%{title: "Elixir in Action"}]}
  end)
```

Each call records its latency. Over time the tracker learns the latency
distribution and adjusts the hedge delay automatically. A built-in token
bucket prevents hedge storms under sustained load.

#### 3. Supervision tree integration

For production use, add the tracker as a child:

```elixir
# In your Application module
children = [
  {Resiliency.Hedged, name: MyApp.SearchHedge, percentile: 95},
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

---

## Deduplicating with SingleFlight

`Resiliency.SingleFlight` ensures that when many processes request the
same expensive computation concurrently, the function executes only once.
All callers receive the same result. This is invaluable for cache
stampede prevention.

### 1. Start the server

```elixir
{:ok, _pid} = Resiliency.SingleFlight.start_link(name: MyApp.Flights)
```

### 2. Deduplicate a database lookup

Suppose 50 requests arrive simultaneously for user 42. Without
SingleFlight, you hit the database 50 times. With it, you hit it once:

```elixir
{:ok, user} =
  Resiliency.SingleFlight.flight(MyApp.Flights, "user:42", fn ->
    # Only one process executes this, even if 50 call concurrently
    Process.sleep(100)
    %{id: 42, name: "Bob", email: "bob@example.com"}
  end)
```

All 50 callers skip the I/O -- they wait for the single execution to complete,
then receive `{:ok, %{id: 42, ...}}` without each doing their own round-trip.

### 3. Forget a key

After a write, you may want the next read to bypass the in-flight
deduplication and fetch fresh data:

```elixir
:ok = Resiliency.SingleFlight.forget(MyApp.Flights, "user:42")
```

Existing waiters still receive the original result. Only new callers
after `forget/2` trigger a fresh execution.

### 4. Caller-side timeout

If you cannot afford to wait forever for a slow in-flight call, pass a
timeout. The calling process exits, but the in-flight function continues
so other waiters still get their result:

```elixir
try do
  Resiliency.SingleFlight.flight(MyApp.Flights, "slow-key", fn ->
    Process.sleep(10_000)
    :result
  end, 1_000)
rescue
  _ -> :timed_out
catch
  :exit, {:timeout, _} -> :timed_out
end
```

### 5. Supervision tree integration

```elixir
children = [
  {Resiliency.SingleFlight, name: MyApp.Flights},
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

---

## Racing Tasks

`Resiliency.Race`, `Resiliency.AllSettled`, `Resiliency.Map`, and
`Resiliency.FirstOk` provide higher-level concurrency combinators
that are stateless -- no GenServer, no supervision tree entry.

### `Race.run/1` -- first success wins

Fire multiple strategies in parallel and take whichever returns first.
Losers are killed automatically:

```elixir
{:ok, data} =
  Resiliency.Race.run([
    fn ->
      # Try the local cache
      Process.sleep(5)
      :cached_value
    end,
    fn ->
      # Fall back to the database
      Process.sleep(50)
      :db_value
    end
  ])

# => {:ok, :cached_value}
```

If a task crashes, the race continues with the remaining tasks:

```elixir
{:ok, :backup} =
  Resiliency.Race.run([
    fn -> raise "primary is down" end,
    fn -> :backup end
  ])
```

### `AllSettled.run/1` -- collect everything

Run tasks in parallel and wait for all of them. Crashes do not propagate
to the caller -- each slot gets `{:ok, value}` or `{:error, reason}`:

```elixir
results =
  Resiliency.AllSettled.run([
    fn -> {:ok, "service_a response"} end,
    fn -> raise "service_b is broken" end,
    fn -> {:ok, "service_c response"} end
  ])

# => [{:ok, {:ok, "service_a response"}},
#     {:error, {%RuntimeError{message: "service_b is broken"}, _stacktrace}},
#     {:ok, {:ok, "service_c response"}}]
```

### `Resiliency.Map.run/3` -- bounded-concurrency parallel map

Process a list of items in parallel with a concurrency cap. On the first
failure, all remaining work is cancelled:

```elixir
urls = [
  "https://api.example.com/users/1",
  "https://api.example.com/users/2",
  "https://api.example.com/users/3",
  "https://api.example.com/users/4",
  "https://api.example.com/users/5"
]

{:ok, responses} =
  Resiliency.Map.run(
    urls,
    fn url ->
      # Simulate fetching each URL
      Process.sleep(Enum.random(10..50))
      %{url: url, status: 200}
    end,
    max_concurrency: 3
  )

# responses is in the same order as urls
```

### `FirstOk.run/1` -- sequential fallback chain

Try data sources one at a time. Stop at the first success. Later sources
are never called if an earlier one succeeds:

```elixir
{:ok, value} =
  Resiliency.FirstOk.run([
    fn ->
      # L1 cache miss
      {:error, :not_found}
    end,
    fn ->
      # L2 cache miss
      {:error, :not_found}
    end,
    fn ->
      # Database hit
      {:ok, %{id: 1, name: "Alice"}}
    end,
    fn ->
      # Remote API -- never called because the DB succeeded
      {:ok, %{id: 1, name: "Alice (stale)"}}
    end
  ])

# => {:ok, %{id: 1, name: "Alice"}}
```

---

## Rate Limiting with WeightedSemaphore

`Resiliency.WeightedSemaphore` bounds concurrent access to a shared
resource. Unlike a standard semaphore, each acquisition can specify a
weight -- useful when different operations have different costs (a bulk
insert costs more than a single read).

### 1. Start the semaphore

```elixir
{:ok, _pid} =
  Resiliency.WeightedSemaphore.start_link(name: MyApp.DbPool, max: 10)
```

### 2. Acquire with default weight (1 permit)

```elixir
{:ok, user} =
  Resiliency.WeightedSemaphore.acquire(MyApp.DbPool, fn ->
    # Runs inside a managed process -- permits auto-release on completion
    Process.sleep(10)
    %{id: 1, name: "Alice"}
  end)
```

### 3. Acquire with a heavier weight

A bulk import might consume 5 of your 10 permits, leaving room for only
5 lightweight reads:

```elixir
{:ok, :imported} =
  Resiliency.WeightedSemaphore.acquire(MyApp.DbPool, 5, fn ->
    # Holds 5 permits for the duration
    Process.sleep(100)
    :imported
  end)
```

### 4. Non-blocking try

When the system is under load, skip optional work instead of queuing:

```elixir
case Resiliency.WeightedSemaphore.try_acquire(MyApp.DbPool, 3, fn ->
  :analytics_write
end) do
  {:ok, :analytics_write} ->
    :ok

  :rejected ->
    # Semaphore is full or a larger waiter is ahead -- drop this work
    :skipped
end
```

### 5. Acquire with a timeout

Block for at most 1 second. If permits are not available by then, give up:

```elixir
case Resiliency.WeightedSemaphore.acquire(MyApp.DbPool, 3, fn ->
  :result
end, 1_000) do
  {:ok, :result} -> :ok
  {:error, :timeout} -> :gave_up
end
```

### 6. Supervision tree integration

In production, start the semaphore under your application supervisor so
it restarts automatically on failure:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Resiliency.WeightedSemaphore, name: MyApp.DbPool, max: 10},
      {Resiliency.WeightedSemaphore, name: MyApp.ExternalApi, max: 5},
      # ... your other children
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### FIFO fairness

Waiters are served in strict FIFO order. If a weight-8 request is at the
front of the queue but only 5 permits are free, a weight-1 request behind
it also blocks -- even though it would fit. This prevents starvation of
large requests.

---

## Combining Patterns

The real power of Resiliency comes from composing primitives. Here is a
function that retries a flaky API call with exponential backoff, and on
each attempt uses hedging to cut tail latency:

```elixir
# Start the hedge tracker (do this once, typically in your supervision tree)
{:ok, _pid} =
  Resiliency.Hedged.start_link(name: MyApp.ApiHedge, percentile: 95)

defmodule MyApp.ResilientClient do
  def fetch_user(user_id) do
    Resiliency.BackoffRetry.retry(
      fn ->
        Resiliency.Hedged.run(MyApp.ApiHedge, fn ->
          # Replace with your real HTTP client
          case :rand.uniform(4) do
            1 -> {:ok, %{id: user_id, name: "Alice"}}
            2 -> {:error, :timeout}
            3 -> {:error, :service_unavailable}
            4 ->
              Process.sleep(500)
              {:ok, %{id: user_id, name: "Alice"}}
          end
        end)
      end,
      max_attempts: 3,
      backoff: :exponential,
      base_delay: 100,
      retry_if: fn
        {:error, :timeout} -> true
        {:error, :service_unavailable} -> true
        _ -> false
      end
    )
  end
end

MyApp.ResilientClient.fetch_user(42)
```

Each attempt fires a hedged pair of requests. If the first attempt fails,
backoff kicks in before the next hedged pair. The result is a function
that tolerates both transient errors (via retry) and slow responses (via
hedging).

---

## Next Steps

Now that you have the fundamentals, explore further:

- **[`Resiliency.BackoffRetry`](Resiliency.BackoffRetry.html)** -- full
  option reference, custom backoff streams, the `Abort` struct, and
  `reraise: true` for preserving stacktraces.
- **[`Resiliency.BackoffRetry.Backoff`](Resiliency.BackoffRetry.Backoff.html)** --
  composable stream-based strategies: `exponential/1`, `linear/1`,
  `constant/1`, `jitter/2`, and `cap/2`.
- **[`Resiliency.Hedged`](Resiliency.Hedged.html)** -- tracker options,
  token bucket tuning, `non_fatal` predicates for immediate re-hedging.
- **[`Resiliency.SingleFlight`](Resiliency.SingleFlight.html)** --
  `forget/2` semantics, timeout behavior, error propagation.
- **[`Resiliency.Race`](Resiliency.Race.html)** -- concurrent race, first success wins.
- **[`Resiliency.AllSettled`](Resiliency.AllSettled.html)** -- concurrent execution, collect all results.
- **[`Resiliency.Map`](Resiliency.Map.html)** -- bounded-concurrency parallel map with fail-fast.
- **[`Resiliency.FirstOk`](Resiliency.FirstOk.html)** -- sequential fallback chain.
- **[`Resiliency.WeightedSemaphore`](Resiliency.WeightedSemaphore.html)** --
  FIFO fairness guarantees, error handling, `try_acquire` vs `acquire`.
