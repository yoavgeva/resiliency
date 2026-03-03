defmodule Resiliency.Telemetry do
  @moduledoc """
  Telemetry events emitted by the Resiliency library.

  All events follow the standard `:telemetry` span convention where applicable:
  `[:resiliency, :module, :action, :start | :stop | :exception]`. Point events
  (non-span) are emitted for significant occurrences like retries, hedges,
  rejections, and state changes.

  Every event is emitted in the **caller's process** except where noted.
  Attaching handlers has zero impact on server throughput for caller-emitted
  events. The `state_change` event for CircuitBreaker is emitted inside the
  GenServer process.

  ## BackoffRetry

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :retry, :start]` | span | `%{system_time: integer}` | `%{max_attempts: integer}` |
  | `[:resiliency, :retry, :stop]` | span | `%{duration: integer}` | `%{max_attempts: integer, attempts: integer, result: :ok \\| :error}` |
  | `[:resiliency, :retry, :exception]` | span | `%{duration: integer}` | `%{max_attempts: integer, attempts: integer, kind: atom, reason: term, stacktrace: list}` |
  | `[:resiliency, :retry, :retry]` | point | `%{delay: integer}` | `%{attempt: integer, error: term}` |

  ## CircuitBreaker

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :circuit_breaker, :call, :start]` | span | `%{system_time: integer}` | `%{name: term}` |
  | `[:resiliency, :circuit_breaker, :call, :stop]` | span | `%{duration: integer}` | `%{name: term, result: :ok \\| :error, error: term \\| nil}` |
  | `[:resiliency, :circuit_breaker, :call, :rejected]` | point | `%{}` | `%{name: term}` |
  | `[:resiliency, :circuit_breaker, :state_change]` | point | `%{}` | `%{name: term, from: atom, to: atom}` |

  ## Bulkhead

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :bulkhead, :call, :start]` | span | `%{system_time: integer}` | `%{name: term}` |
  | `[:resiliency, :bulkhead, :call, :stop]` | span | `%{duration: integer}` | `%{name: term, result: :ok \\| :error, error: term \\| nil}` |
  | `[:resiliency, :bulkhead, :call, :rejected]` | point | `%{}` | `%{name: term}` |
  | `[:resiliency, :bulkhead, :call, :permitted]` | point | `%{}` | `%{name: term}` |

  ## Hedged

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :hedged, :run, :start]` | span | `%{system_time: integer}` | `%{mode: :stateless \\| :adaptive}` |
  | `[:resiliency, :hedged, :run, :stop]` | span | `%{duration: integer}` | `%{mode: atom, result: :ok \\| :error, dispatched: integer, hedged: boolean}` |
  | `[:resiliency, :hedged, :hedge]` | point | `%{}` | `%{attempt: integer}` |

  ## SingleFlight

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :single_flight, :flight, :start]` | span | `%{system_time: integer}` | `%{name: term, key: term}` |
  | `[:resiliency, :single_flight, :flight, :stop]` | span | `%{duration: integer}` | `%{name: term, key: term, result: :ok \\| :error, shared: boolean}` |
  | `[:resiliency, :single_flight, :flight, :exception]` | span | `%{duration: integer}` | `%{name: term, key: term, kind: atom, reason: term, stacktrace: list}` |

  ## WeightedSemaphore

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :semaphore, :acquire, :start]` | span | `%{system_time: integer}` | `%{name: term, weight: integer}` |
  | `[:resiliency, :semaphore, :acquire, :stop]` | span | `%{duration: integer}` | `%{name: term, weight: integer, result: :ok \\| :error \\| :rejected}` |
  | `[:resiliency, :semaphore, :acquire, :rejected]` | point | `%{}` | `%{name: term, weight: integer}` |

  ## Race

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :race, :run, :start]` | span | `%{system_time: integer}` | `%{count: integer}` |
  | `[:resiliency, :race, :run, :stop]` | span | `%{duration: integer}` | `%{count: integer, result: :ok \\| :error}` |
  | `[:resiliency, :race, :run, :exception]` | span | `%{duration: integer}` | `%{count: integer, kind: atom, reason: term, stacktrace: list}` |

  ## AllSettled

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :all_settled, :run, :start]` | span | `%{system_time: integer}` | `%{count: integer}` |
  | `[:resiliency, :all_settled, :run, :stop]` | span | `%{duration: integer}` | `%{count: integer, ok_count: integer, error_count: integer}` |
  | `[:resiliency, :all_settled, :run, :exception]` | span | `%{duration: integer}` | `%{count: integer, kind: atom, reason: term, stacktrace: list}` |

  ## Map

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :map, :run, :start]` | span | `%{system_time: integer}` | `%{count: integer, max_concurrency: integer}` |
  | `[:resiliency, :map, :run, :stop]` | span | `%{duration: integer}` | `%{count: integer, max_concurrency: integer, result: :ok \\| :error}` |
  | `[:resiliency, :map, :run, :exception]` | span | `%{duration: integer}` | `%{count: integer, max_concurrency: integer, kind: atom, reason: term, stacktrace: list}` |

  ## FirstOk

  | Event | Type | Measurements | Metadata |
  |---|---|---|---|
  | `[:resiliency, :first_ok, :run, :start]` | span | `%{system_time: integer}` | `%{count: integer}` |
  | `[:resiliency, :first_ok, :run, :stop]` | span | `%{duration: integer}` | `%{count: integer, result: :ok \\| :error, attempts: integer}` |
  | `[:resiliency, :first_ok, :run, :exception]` | span | `%{duration: integer}` | `%{count: integer, kind: atom, reason: term, stacktrace: list}` |
  """
end
