# Changelog

## 0.5.0 (2026-03-03)

### New features

- **Built-in telemetry** — all 10 modules now emit `:telemetry` events following
  the standard span convention (`start` / `stop` / `exception`) plus point events
  for significant occurrences (`retry`, `hedge`, `rejected`, `permitted`, `state_change`).
  Zero configuration required; attach handlers with the standard `:telemetry` API.
  See `Resiliency.Telemetry` for the complete event catalogue.

- **`Resiliency.Bulkhead`** — new module. Isolates workloads with per-partition
  concurrency limits. Supports configurable queue depth (`max_queue`) and optional
  caller-side wait timeout (`max_wait`). Rejects immediately when queue is full.

### Bug fixes

- `Resiliency.WeightedSemaphore` — `try_acquire/3` now wraps the GenServer call in
  `try/catch` so process exits close the telemetry span instead of leaking it.
- `Resiliency.WeightedSemaphore` — `acquire/4` now handles all exit reasons, not
  just `{:timeout, _}`. Non-timeout exits re-exit after emitting a `:stop` event.
- `Resiliency.SingleFlight` — `flight/3` now wraps the GenServer call in `try/catch`,
  matching the behaviour of `flight/4` and ensuring the span is always closed.

## 0.4.0

- Add `Resiliency.CircuitBreaker` with sliding-window failure-rate tracking and
  automatic half-open probing.

## 0.3.1

- Fix flaky FIFO ordering test in `WeightedSemaphore`.

## 0.3.0

- Split `TaskExtension` into top-level `Race`, `AllSettled`, `Map`, `FirstOk` modules.

## 0.2.0

- Initial public release with `BackoffRetry`, `Hedged`, `SingleFlight`,
  `WeightedSemaphore`, and task combinators.
