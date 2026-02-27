defmodule Resiliency do
  @moduledoc """
  Resilience and concurrency toolkit for Elixir.

  This library bundles five complementary modules that help your application
  handle failures, bound concurrency, and reduce tail latency — all with
  zero runtime dependencies.

  ## Modules

    * `Resiliency.BackoffRetry` — Functional retry with composable, stream-based backoff strategies.
    * `Resiliency.Hedged` — Hedged requests: fire a backup after a delay, take whichever finishes first.
    * `Resiliency.SingleFlight` — Deduplicate concurrent function calls by key.
    * `Resiliency.TaskExtension` — Higher-level Task combinators: `race`, `all_settled`, `map`, `first_ok`.
    * `Resiliency.WeightedSemaphore` — Weighted semaphore for bounding concurrent access to a shared resource.

  ## Common API patterns

  Most modules in this library follow a consistent workflow:

  1. **Start** — Add the module to your supervision tree (where applicable).
     Only `Resiliency.Hedged` (adaptive mode), `Resiliency.SingleFlight`, and
     `Resiliency.WeightedSemaphore` require a running process. `BackoffRetry`,
     `TaskExtension`, and stateless `Hedged.run/2` are purely functional.

  2. **Call** — Wrap your operation in a zero-arity function and pass it to the
     module's primary entry point:

         # Retry
         Resiliency.BackoffRetry.retry(fn -> fetch(url) end, max_attempts: 5)

         # Hedged (stateless)
         Resiliency.Hedged.run(fn -> fetch(url) end, delay: 100)

         # Hedged (adaptive)
         Resiliency.Hedged.run(MyHedge, fn -> fetch(url) end)

         # SingleFlight
         Resiliency.SingleFlight.flight(MyFlights, "user:123", fn -> load_user(123) end)

         # TaskExtension
         Resiliency.TaskExtension.race([fn -> svc_a() end, fn -> svc_b() end])

         # WeightedSemaphore
         Resiliency.WeightedSemaphore.acquire(MySem, 3, fn -> bulk_insert(rows) end)

  3. **Handle the result** — Every module returns `{:ok, value}` on success and
     `{:error, reason}` on failure, so pattern matching is uniform across the
     entire toolkit.

  Combine modules for layered resilience — for example, wrap a hedged call
  inside a retry, or protect a retried call behind a weighted semaphore to
  avoid overwhelming a downstream service.
  """
end
