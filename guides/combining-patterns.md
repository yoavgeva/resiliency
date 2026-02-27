# Combining Patterns

Each module in Resiliency addresses a distinct failure mode -- retries smooth
over transient errors, hedged requests cut tail latency, single-flight
deduplication collapses thundering herds, and weighted semaphores bound
downstream pressure. In isolation, each is useful. Combined, they form a
defense-in-depth strategy that handles the full spectrum of production failures.

This guide walks through concrete composition patterns, building from simple
two-module combinations to a full resilience stack. Every example is a complete,
runnable module -- copy it into your project and adapt the function bodies.

---

## Why Combine?

A single resilience primitive covers one failure mode. Real systems face several
at once:

| Failure mode | Primitive | What it does |
|---|---|---|
| Transient errors (503s, timeouts) | `BackoffRetry` | Retries with backoff until success or budget exhaustion |
| Tail latency (p99 spikes) | `Hedged` | Fires a backup request after a delay, takes whichever finishes first |
| Thundering herd (cache stampede) | `SingleFlight` | Deduplicates concurrent calls so the function executes once per key |
| Downstream overload | `WeightedSemaphore` | Bounds concurrency to protect the downstream service |

When you call an external payment API, a single retry loop is not enough. The
payment service might be slow (hedging helps), your retries might fan out across
hundreds of pods (single-flight collapses them), and your retry storms might
overwhelm the service entirely (semaphore caps concurrency). Combining patterns
gives you defense at every layer.

The key insight: **compose from the outside in**. The outermost wrapper controls
the broadest concern (deduplication, concurrency limits), and the innermost
wrapper handles the narrowest (individual request hedging, retry logic).

---

## Pattern: Retry + Hedged Requests

**Scenario** -- You are calling a slow search service. Individual requests
sometimes time out (transient failure), and tail latency is high (p99 is 3x
the median). You want to hedge each attempt *and* retry the entire hedged call
if both the primary and hedge fail.

The retry loop wraps the hedged call. Each "attempt" from BackoffRetry's
perspective is a full hedged execution -- primary plus backup.

```elixir
defmodule MyApp.Search do
  @moduledoc """
  Search client with retry-wrapped hedged requests.

  Each retry attempt fires a hedged request (primary + backup).
  If both the primary and hedge fail, BackoffRetry sleeps and
  tries again.
  """

  require Logger

  @doc """
  Queries the search service with hedged requests and retry.

  Returns `{:ok, results}` or `{:error, reason}` after all
  retries are exhausted.
  """
  @spec search(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def search(query, opts \\ []) do
    tracker = Keyword.get(opts, :tracker, MyApp.Search.Tracker)

    Resiliency.BackoffRetry.retry(
      fn ->
        case Resiliency.Hedged.run(tracker, fn -> do_search(query) end, timeout: 3_000) do
          {:ok, results} -> {:ok, results}
          {:error, reason} -> {:error, reason}
        end
      end,
      max_attempts: 3,
      backoff: :exponential,
      base_delay: 200,
      max_delay: 2_000,
      budget: 10_000,
      retry_if: fn
        {:error, :timeout} -> true
        {:error, :service_unavailable} -> true
        {:error, _} -> false
      end,
      on_retry: fn attempt, delay, error ->
        Logger.warning(
          "Search retry attempt=#{attempt} delay=#{delay}ms error=#{inspect(error)}"
        )
      end
    )
  end

  defp do_search(query) do
    case HttpClient.post("https://search.internal/query", %{q: query}) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 503}} -> {:error, :service_unavailable}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Supervision tree

The `Hedged.Tracker` is a GenServer that must be started before any calls to
`Resiliency.Hedged.run/3`. Place it in your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Resiliency.Hedged,
       name: MyApp.Search.Tracker,
       percentile: 95,
       min_delay: 10,
       max_delay: 2_000,
       initial_delay: 150}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### How the layers interact

1. `BackoffRetry.retry/2` calls the anonymous function -- attempt 1.
2. Inside, `Hedged.run/3` fires the primary `do_search/1`. If the primary is
   slower than p95, a backup fires after the adaptive delay.
3. Whichever finishes first wins. If both fail, `Hedged.run/3` returns
   `{:error, reason}`.
4. `BackoffRetry` checks `retry_if` -- if the error is retryable, it sleeps
   with exponential backoff and loops back to step 1.
5. The `:budget` option ensures the entire retry+hedge sequence completes
   within 10 seconds, regardless of how many attempts remain.

---

## Pattern: Hedged Requests + WeightedSemaphore

**Scenario** -- You are calling an external payment API with hedged requests to
reduce tail latency. But hedging doubles your outbound request rate in the worst
case, and the payment API has a strict rate limit. You need to throttle the
total number of in-flight requests -- including hedges.

The semaphore wraps the hedged call. Each hedged execution (which may spawn up
to `max_requests` concurrent calls) consumes a weight from the semaphore. This
bounds the total downstream pressure.

```elixir
defmodule MyApp.PaymentGateway do
  @moduledoc """
  Payment API client with hedged requests throttled by a
  weighted semaphore.

  The semaphore ensures at most 5 hedged executions run
  concurrently. Since each hedged execution may fire up to
  2 requests (primary + hedge), the downstream API sees at
  most 10 in-flight requests from this node.
  """

  require Logger

  @semaphore MyApp.PaymentGateway.Semaphore
  @tracker MyApp.PaymentGateway.Tracker

  @doc """
  Charges a payment method. Returns `{:ok, transaction}` or
  `{:error, reason}`.

  If the semaphore is at capacity, the caller blocks (FIFO)
  until a slot opens. Use `charge/3` with a timeout to fail
  fast under sustained load.
  """
  @spec charge(String.t(), pos_integer()) :: {:ok, map()} | {:error, any()}
  def charge(payment_method_id, amount_cents) do
    charge(payment_method_id, amount_cents, :infinity)
  end

  @spec charge(String.t(), pos_integer(), timeout()) :: {:ok, map()} | {:error, any()}
  def charge(payment_method_id, amount_cents, timeout) do
    # Weight of 2: each hedged execution may fire 2 downstream requests.
    case Resiliency.WeightedSemaphore.acquire(@semaphore, 2, fn ->
           Resiliency.Hedged.run(@tracker, fn ->
             do_charge(payment_method_id, amount_cents)
           end, timeout: 5_000)
         end, timeout) do
      {:ok, {:ok, transaction}} -> {:ok, transaction}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :timeout} -> {:error, :throttled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Non-blocking variant. Returns `:rejected` immediately if the
  semaphore has no capacity -- useful for shedding load at the
  edge.
  """
  @spec try_charge(String.t(), pos_integer()) :: {:ok, map()} | {:error, any()} | :rejected
  def try_charge(payment_method_id, amount_cents) do
    case Resiliency.WeightedSemaphore.try_acquire(@semaphore, 2, fn ->
           Resiliency.Hedged.run(@tracker, fn ->
             do_charge(payment_method_id, amount_cents)
           end, timeout: 5_000)
         end) do
      {:ok, {:ok, transaction}} -> {:ok, transaction}
      {:ok, {:error, reason}} -> {:error, reason}
      :rejected -> :rejected
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_charge(payment_method_id, amount_cents) do
    payload = %{payment_method: payment_method_id, amount: amount_cents, currency: "usd"}

    case HttpClient.post("https://payments.example.com/v1/charges", payload) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 402, body: body}} -> {:error, {:payment_declined, body}}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Supervision tree

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Hedged tracker -- adapts delay based on observed payment API latency
      {Resiliency.Hedged,
       name: MyApp.PaymentGateway.Tracker,
       percentile: 99,
       min_delay: 50,
       max_delay: 3_000,
       initial_delay: 500},

      # Semaphore -- max weight of 10 permits.
      # Each hedged call acquires weight 2, so at most 5 hedged
      # executions (= 10 downstream requests) run concurrently.
      {Resiliency.WeightedSemaphore,
       name: MyApp.PaymentGateway.Semaphore,
       max: 10}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Why weight 2?

Each hedged execution may fire up to 2 requests (the primary, then the backup
after the adaptive delay). By acquiring weight 2 from a semaphore with max 10,
you guarantee at most 10 concurrent HTTP requests hit the payment API -- even
when every call triggers a hedge. If you set `max_requests: 3` on the hedged
call, you would acquire weight 3 instead.

---

## Pattern: SingleFlight + Retry

**Scenario** -- Your application caches user profiles in Redis. On a cache miss,
you fetch from the database. Under load, hundreds of concurrent requests for the
same user all miss the cache simultaneously and stampede the database. You want
to deduplicate those concurrent fetches *and* retry transient database errors.

SingleFlight wraps the retry. All concurrent callers for the same key share a
single retry loop. If the retry succeeds, everyone gets the result. If it fails,
everyone gets the error.

```elixir
defmodule MyApp.UserProfile do
  @moduledoc """
  User profile loader with single-flight deduplication and retry.

  Concurrent requests for the same user ID are collapsed into a
  single database fetch. The fetch itself retries transient errors
  with exponential backoff.
  """

  require Logger

  @flight MyApp.UserProfile.Flight

  @doc """
  Loads a user profile by ID.

  On a cache hit, returns immediately. On a cache miss, a single
  database fetch runs -- even if 100 callers request the same user
  concurrently. The fetch retries up to 3 times on transient errors.
  """
  @spec get(pos_integer()) :: {:ok, map()} | {:error, any()}
  def get(user_id) do
    case Cache.get("user:#{user_id}") do
      {:ok, profile} ->
        {:ok, profile}

      :miss ->
        Resiliency.SingleFlight.flight(@flight, "user:#{user_id}", fn ->
          fetch_with_retry(user_id)
        end)
    end
  end

  defp fetch_with_retry(user_id) do
    case Resiliency.BackoffRetry.retry(
           fn -> fetch_from_db(user_id) end,
           max_attempts: 3,
           backoff: :exponential,
           base_delay: 50,
           max_delay: 1_000,
           retry_if: fn
             {:error, :timeout} -> true
             {:error, :connection_lost} -> true
             {:error, _} -> false
           end,
           on_retry: fn attempt, delay, error ->
             Logger.warning(
               "UserProfile.fetch retry user_id=#{user_id} " <>
                 "attempt=#{attempt} delay=#{delay}ms error=#{inspect(error)}"
             )
           end
         ) do
      {:ok, profile} ->
        Cache.put("user:#{user_id}", profile, ttl: :timer.minutes(5))
        profile

      {:error, reason} ->
        raise "Failed to fetch user #{user_id}: #{inspect(reason)}"
    end
  end

  defp fetch_from_db(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, Map.from_struct(user)}
    end
  end
end
```

### Supervision tree

```elixir
children = [
  {Resiliency.SingleFlight, name: MyApp.UserProfile.Flight}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Ordering matters

Note that SingleFlight is the *outer* layer and retry is the *inner* layer.
This is intentional:

- **SingleFlight outside, retry inside** -- 100 concurrent callers produce 1
  retry loop with at most 3 database queries. This is what you want.
- **Retry outside, SingleFlight inside** -- 100 concurrent callers each start
  their own retry loop. Each attempt deduplicates, but you still have 100
  independent retry loops burning CPU and memory. Avoid this.

Always place deduplication outside retry.

---

## Pattern: Full Resilience Stack

**Scenario** -- You are building a product catalog service that queries a slow,
occasionally unreliable upstream inventory API. The API has rate limits, high
tail latency, and transient 503 errors. Multiple pods may request the same
product concurrently after a cache miss. You need all four primitives working
together.

The composition order, from outermost to innermost:

1. **SingleFlight** -- Deduplicate concurrent callers for the same product.
2. **WeightedSemaphore** -- Bound total concurrent outbound requests.
3. **BackoffRetry** -- Retry transient failures with exponential backoff.
4. **Hedged** -- Cut tail latency on each individual attempt.

```elixir
defmodule MyApp.Inventory do
  @moduledoc """
  Inventory client combining all four resilience patterns.

  Layer order (outside to inside):
    1. SingleFlight  -- collapse concurrent callers per product
    2. Semaphore     -- bound outbound concurrency
    3. BackoffRetry  -- retry transient errors
    4. Hedged        -- cut tail latency per attempt
  """

  require Logger

  @flight MyApp.Inventory.Flight
  @semaphore MyApp.Inventory.Semaphore
  @tracker MyApp.Inventory.Tracker

  @doc """
  Fetches inventory for a product by SKU.

  Returns `{:ok, inventory}` or `{:error, reason}`.
  """
  @spec get_inventory(String.t()) :: {:ok, map()} | {:error, any()}
  def get_inventory(sku) do
    case Cache.get("inventory:#{sku}") do
      {:ok, data} ->
        {:ok, data}

      :miss ->
        fetch_inventory(sku)
    end
  end

  defp fetch_inventory(sku) do
    # Layer 1: SingleFlight -- deduplicate concurrent callers
    Resiliency.SingleFlight.flight(@flight, "inventory:#{sku}", fn ->
      # Layer 2: WeightedSemaphore -- bound concurrency
      case Resiliency.WeightedSemaphore.acquire(@semaphore, 2, fn ->
             # Layer 3: BackoffRetry -- retry transient errors
             Resiliency.BackoffRetry.retry(
               fn ->
                 # Layer 4: Hedged -- cut tail latency
                 case Resiliency.Hedged.run(@tracker, fn ->
                        fetch_from_api(sku)
                      end, timeout: 4_000) do
                   {:ok, data} -> {:ok, data}
                   {:error, reason} -> {:error, reason}
                 end
               end,
               max_attempts: 3,
               backoff: :exponential,
               base_delay: 100,
               max_delay: 2_000,
               budget: 8_000,
               retry_if: fn
                 {:error, :timeout} -> true
                 {:error, :service_unavailable} -> true
                 {:error, :rate_limited} -> true
                 {:error, _} -> false
               end,
               on_retry: fn attempt, delay, error ->
                 Logger.warning(
                   "Inventory.fetch retry sku=#{sku} " <>
                     "attempt=#{attempt} delay=#{delay}ms error=#{inspect(error)}"
                 )
               end
             )
           end) do
        {:ok, {:ok, data}} ->
          Cache.put("inventory:#{sku}", data, ttl: :timer.seconds(30))
          data

        {:ok, {:error, reason}} ->
          raise "Inventory API error for #{sku}: #{inspect(reason)}"

        {:error, reason} ->
          raise "Semaphore error for #{sku}: #{inspect(reason)}"
      end
    end)
  end

  defp fetch_from_api(sku) do
    case HttpClient.get("https://inventory.internal/v2/products/#{sku}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: 503}} -> {:error, :service_unavailable}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Full supervision tree

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # -- Inventory resilience stack --
      {Resiliency.SingleFlight, name: MyApp.Inventory.Flight},

      {Resiliency.WeightedSemaphore,
       name: MyApp.Inventory.Semaphore,
       max: 20},

      {Resiliency.Hedged,
       name: MyApp.Inventory.Tracker,
       percentile: 95,
       min_delay: 10,
       max_delay: 2_000,
       initial_delay: 200,
       min_samples: 20}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Request flow

Here is what happens when 50 concurrent requests arrive for the same SKU,
all missing the cache:

1. **SingleFlight** -- All 50 callers call `flight/3` with key
   `"inventory:sku-123"`. Only the first caller executes the function. The
   other 49 block, waiting for the result.
2. **WeightedSemaphore** -- The single executing caller acquires weight 2 from
   the semaphore. If the semaphore is already at capacity from other SKU
   fetches, this caller blocks in FIFO order.
3. **BackoffRetry** -- The caller enters the retry loop. Attempt 1 begins.
4. **Hedged** -- The primary request fires. If it is slower than p95 (tracked
   adaptively), a backup fires after the adaptive delay. Whichever responds
   first wins.
5. If the hedged call returns `{:error, :service_unavailable}`, BackoffRetry
   checks `retry_if`, sleeps with exponential backoff, and loops to step 4.
6. On success, the result propagates back up: the semaphore releases its
   permits, SingleFlight broadcasts the result to all 49 waiting callers,
   and the cache is populated.

Total downstream impact from 50 concurrent callers: at most 3 attempts x 2
hedged requests = 6 HTTP requests, all bounded by the semaphore.

---

## Supervision Tree Design

When combining multiple patterns, all stateful components -- `Hedged.Tracker`,
`SingleFlight`, and `WeightedSemaphore` -- need to be started under a
supervisor. `BackoffRetry` and `TaskExtension` are stateless and require no
supervision.

### Grouping by domain

Group resilience infrastructure by the domain it serves. This makes it clear
which components belong together and simplifies restarts:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Application-level services
      MyApp.Repo,
      MyApp.Cache,

      # Resilience infrastructure -- grouped by domain
      {Supervisor, name: MyApp.ResiliencySupervisor, children: resilience_children(),
       strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp resilience_children do
    [
      # -- Payment gateway stack --
      {Resiliency.Hedged,
       name: MyApp.PaymentGateway.Tracker,
       percentile: 99,
       min_delay: 50,
       max_delay: 3_000,
       initial_delay: 500},

      {Resiliency.WeightedSemaphore,
       name: MyApp.PaymentGateway.Semaphore,
       max: 10},

      # -- Search stack --
      {Resiliency.Hedged,
       name: MyApp.Search.Tracker,
       percentile: 95,
       min_delay: 10,
       max_delay: 2_000,
       initial_delay: 150},

      # -- User profile stack --
      {Resiliency.SingleFlight,
       name: MyApp.UserProfile.Flight},

      # -- Inventory stack --
      {Resiliency.SingleFlight,
       name: MyApp.Inventory.Flight},

      {Resiliency.WeightedSemaphore,
       name: MyApp.Inventory.Semaphore,
       max: 20},

      {Resiliency.Hedged,
       name: MyApp.Inventory.Tracker,
       percentile: 95,
       min_delay: 10,
       max_delay: 2_000,
       initial_delay: 200}
    ]
  end
end
```

### Child spec reference

Each stateful module provides a `child_spec/1` that works with standard
`Supervisor` syntax:

```elixir
# Hedged.Tracker -- adaptive delay + token-bucket throttling
{Resiliency.Hedged, name: MyApp.HedgeTracker, percentile: 95}

# SingleFlight -- concurrent call deduplication
{Resiliency.SingleFlight, name: MyApp.Flights}

# WeightedSemaphore -- bounded concurrency
{Resiliency.WeightedSemaphore, name: MyApp.Semaphore, max: 10}
```

Each spec uses the `:name` as its child ID, so you can run multiple instances
without conflict:

```elixir
children = [
  {Resiliency.Hedged, name: MyApp.SearchTracker, percentile: 95},
  {Resiliency.Hedged, name: MyApp.PaymentTracker, percentile: 99}
]
```

### Restart strategy

Use `:one_for_one` for resilience components. They are independent of each
other -- a crashed semaphore should not take down the hedge tracker. If a
component crashes and restarts, callers that were blocked on it will receive an
exit signal, which propagates naturally through the retry/hedging layers and
triggers a retry on the next attempt.

---

## Production Considerations

### Telemetry hooks

Use the `:on_retry` callback in BackoffRetry and `:on_hedge` in Hedged to emit
telemetry events for observability:

```elixir
defmodule MyApp.ResiliencyTelemetry do
  @moduledoc """
  Telemetry callbacks for resilience patterns.
  """

  def on_retry(attempt, delay, error) do
    :telemetry.execute(
      [:my_app, :resilience, :retry],
      %{attempt: attempt, delay_ms: delay},
      %{error: error}
    )
  end

  def on_hedge(attempt) do
    :telemetry.execute(
      [:my_app, :resilience, :hedge],
      %{attempt: attempt},
      %{}
    )
  end
end
```

Wire them into your calls:

```elixir
Resiliency.BackoffRetry.retry(fun,
  on_retry: &MyApp.ResiliencyTelemetry.on_retry/3
)

Resiliency.Hedged.run(tracker, fun,
  on_hedge: &MyApp.ResiliencyTelemetry.on_hedge/1
)
```

The `Hedged.Tracker` also exposes `stats/1` for periodic scraping:

```elixir
# In a periodic reporter or health check
stats = Resiliency.Hedged.Tracker.stats(MyApp.Search.Tracker)
# => %{total_requests: 12450, hedged_requests: 623, hedge_won: 198,
#       p50: 12, p95: 87, p99: 340, current_delay: 87, tokens: 7.3}
```

### Circuit breakers

Resiliency does not include a circuit breaker. If you need one -- for example,
to stop calling a downstream service that has been failing for minutes -- layer
it as the outermost wrapper, before SingleFlight:

```elixir
# Pseudocode -- use a circuit breaker library of your choice
case CircuitBreaker.call(:payment_api, fn ->
       Resiliency.SingleFlight.flight(@flight, key, fn ->
         # ... semaphore + retry + hedge ...
       end)
     end) do
  {:ok, result} -> result
  {:error, :circuit_open} -> {:error, :service_degraded}
end
```

The circuit breaker sits outside the entire stack because it makes a
binary decision -- call or reject -- before any other work happens. This
prevents retries and hedges from running against a service that is known
to be down.

### Graceful degradation

Design your callers to degrade gracefully when the resilience stack fails:

```elixir
defmodule MyApp.ProductPage do
  @moduledoc """
  Product page assembly with graceful degradation.
  """

  def render(product_id) do
    product = MyApp.Catalog.get!(product_id)

    inventory =
      case MyApp.Inventory.get_inventory(product.sku) do
        {:ok, data} -> data
        {:error, _reason} -> %{available: nil, message: "Check back shortly"}
      end

    reviews =
      case MyApp.Reviews.get_reviews(product_id) do
        {:ok, data} -> data
        {:error, _reason} -> []
      end

    %{product: product, inventory: inventory, reviews: reviews}
  end
end
```

The core product data is required -- if it fails, the page fails. But inventory
and reviews are optional. When the inventory API is down and all retries are
exhausted, the page still renders with a placeholder message instead of a 500
error.

### Timeout budgets

When stacking multiple patterns, be deliberate about timeout budgets. A common
mistake is setting generous timeouts at every layer, causing requests to hang
for far too long:

| Layer | Timeout | Rationale |
|---|---|---|
| HTTP client | 3 s | Single request deadline |
| Hedged | 4 s | Slightly above HTTP timeout to allow the hedge to complete |
| BackoffRetry `:budget` | 8 s | Total time for all retry attempts combined |
| WeightedSemaphore | 10 s | Includes queuing time waiting for a permit |
| Caller-facing deadline | 12 s | Outermost deadline the user experiences |

The outer timeout must always be larger than the inner timeout. If your semaphore
timeout is shorter than your retry budget, the semaphore will kill the request
while retries are still in progress.

### Abort on non-retryable errors

Use `BackoffRetry.abort/1` to short-circuit the retry loop when you know the
error is permanent:

```elixir
Resiliency.BackoffRetry.retry(fn ->
  case HttpClient.post(url, payload) do
    {:ok, %{status: 200, body: body}} ->
      {:ok, body}

    {:ok, %{status: 400, body: body}} ->
      # Client error -- retrying won't help
      {:error, Resiliency.BackoffRetry.abort({:bad_request, body})}

    {:ok, %{status: 503}} ->
      {:error, :service_unavailable}

    {:error, reason} ->
      {:error, reason}
  end
end)
```

This prevents wasting retry budget on errors that will never succeed, and it
propagates the abort through SingleFlight to all waiting callers immediately.
