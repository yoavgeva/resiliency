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
  """
end
