# Resiliency

A collection of resilience and concurrency primitives for Elixir.

| Module | Description |
|---|---|
| `Resiliency.BackoffRetry` | Retry with configurable backoff strategies (constant, exponential, linear, jitter) |
| `Resiliency.Hedged` | Hedged requests — send a backup after a percentile-based delay to cut tail latency |
| `Resiliency.SingleFlight` | Deduplicate concurrent calls to the same key so the function executes only once |
| `Resiliency.TaskExtension` | Task combinators: `race`, `all_settled`, `map`, `first_ok` |
| `Resiliency.WeightedSemaphore` | Weighted semaphore with FIFO fairness and timeout support |

## Installation

Add `resiliency` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:resiliency, "~> 0.1.0"}
  ]
end
```

## Quick Start

### BackoffRetry

```elixir
Resiliency.BackoffRetry.retry(max_retries: 3, backoff: :exponential) do
  case HttpClient.get(url) do
    {:ok, %{status: 200}} = success -> success
    {:ok, %{status: 503}} -> raise "service unavailable"
    {:error, reason} -> raise "request failed: #{inspect(reason)}"
  end
end
```

### Hedged

```elixir
# Start a tracker (typically in your supervision tree)
{:ok, tracker} = Resiliency.Hedged.start_link(name: :my_hedged, percentile: 95)

# Hedged call — sends a backup request if the first is slower than p95
{:ok, result} = Resiliency.Hedged.run(:my_hedged, fn -> expensive_call() end)
```

### SingleFlight

```elixir
# Start under a supervisor
{:ok, sf} = Resiliency.SingleFlight.start_link(name: :my_sf)

# 100 concurrent callers with the same key — function runs only once
{:ok, data} = Resiliency.SingleFlight.flight(:my_sf, "user:123", fn ->
  Database.get_user(123)
end)
```

### TaskExtension

```elixir
# Race — first success wins, losers are killed
{:ok, fastest} = Resiliency.TaskExtension.race([
  fn -> fetch_from_cache() end,
  fn -> fetch_from_db() end
])

# Parallel map with bounded concurrency
{:ok, results} = Resiliency.TaskExtension.map(urls, &fetch/1, max_concurrency: 10)

# all_settled — never short-circuits, collects all results
results = Resiliency.TaskExtension.all_settled([fn -> risky_op() end, ...])

# first_ok — sequential fallback chain
{:ok, value} = Resiliency.TaskExtension.first_ok([
  fn -> try_cache() end,
  fn -> try_db() end,
  fn -> try_api() end
])
```

### WeightedSemaphore

```elixir
# Start under a supervisor
children = [{Resiliency.WeightedSemaphore, name: :my_sem, max: 10}]

# Acquire with weight
{:ok, result} = Resiliency.WeightedSemaphore.acquire(:my_sem, 3, fn ->
  heavy_operation()
end)

# Non-blocking try
:rejected = Resiliency.WeightedSemaphore.try_acquire(:my_sem, 5, fn -> :work end)
```

## Migration from Individual Packages

If you were using any of the standalone packages (`backoff_retry`, `hedged`, `single_flight`, `task_extension`, `weighted_semaphore`), update your dependencies and add a `Resiliency.` prefix to all module references:

| Before | After |
|---|---|
| `BackoffRetry.retry(...)` | `Resiliency.BackoffRetry.retry(...)` |
| `Hedged.run(...)` | `Resiliency.Hedged.run(...)` |
| `SingleFlight.flight(...)` | `Resiliency.SingleFlight.flight(...)` |
| `TaskExtension.race(...)` | `Resiliency.TaskExtension.race(...)` |
| `WeightedSemaphore.acquire(...)` | `Resiliency.WeightedSemaphore.acquire(...)` |

## License

MIT — see [LICENSE](LICENSE).
