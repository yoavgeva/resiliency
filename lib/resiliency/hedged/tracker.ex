defmodule Resiliency.Hedged.Tracker do
  @moduledoc """
  Adaptive delay tracker with token-bucket hedge throttling.

  Maintains a rolling window of latency samples and computes a target
  percentile to use as the hedge delay. A token bucket limits the overall
  hedge rate: each request credits a small amount, each hedge costs more,
  so hedging naturally throttles under load.

  ## How it works

  The tracker is a GenServer that holds two pieces of mutable state: a
  `Resiliency.Hedged.Percentile` circular buffer of recent latency samples,
  and a floating-point token bucket.

  **Adaptive delay** — After every completed request, the caller records the
  observed latency via `record/2`. The sample is added to the circular buffer
  (see `Resiliency.Hedged.Percentile`). When `get_config/1` is called, the
  tracker computes the configured percentile (e.g., p95) of the buffered
  samples and clamps the result to `[min_delay, max_delay]`. Until at least
  `:min_samples` observations have been recorded, the tracker returns
  `:initial_delay` instead — a sensible default while the system warms up.

  **Token bucket** — Each completed request credits `:token_success_credit`
  tokens (default 0.1). Each hedge that fires costs `:token_hedge_cost`
  tokens (default 1.0). Hedging is only allowed when the bucket contains at
  least `:token_threshold` tokens. Because a hedge costs 10x what a success
  earns, hedging naturally throttles to roughly 10% of traffic under
  sustained load. If hedges consistently win (indicating a real latency
  problem rather than a transient spike), the bucket refills quickly and
  hedging continues. If hedges rarely help, the bucket drains and hedging
  pauses — protecting the downstream service from unnecessary duplicate load.

  **Statistics** — `stats/1` returns a snapshot of counters (total requests,
  hedged requests, hedge wins), percentiles (p50, p95, p99), the current
  adaptive delay, and the token bucket level. This is useful for dashboards
  and alerting.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `start_link/1` | O(1) | O(1) — empty buffer and initial token bucket |
  | `get_config/1` | O(1) — percentile lookup is O(1) via tuple indexing | O(1) |
  | `record/2` | O(n) where n = `buffer_size` — sorted insert/delete on the internal sorted list | O(n) — the circular buffer holds at most n samples |
  | `stats/1` | O(1) — percentile lookups are O(1) | O(1) |

  ## Usage

      {:ok, _} = Resiliency.Hedged.Tracker.start_link(name: MyTracker)

      # Query the current adaptive delay and whether hedging is allowed
      {delay, allow?} = Resiliency.Hedged.Tracker.get_config(MyTracker)

      # Record an observation after a request completes
      Resiliency.Hedged.Tracker.record(MyTracker, %{latency_ms: 42, hedged?: false, hedge_won?: false})

      # Inspect tracker state
      Resiliency.Hedged.Tracker.stats(MyTracker)

  In most cases you won't call these functions directly — `Resiliency.Hedged.run/3`
  does it automatically when you pass a tracker name.

  ## Options

    * `:name` — required, the registered name for the tracker process
    * `:percentile` — target percentile for adaptive delay (default: `95`)
    * `:buffer_size` — max latency samples to keep (default: `1000`)
    * `:min_delay` — floor for adaptive delay in ms (default: `1`)
    * `:max_delay` — ceiling for adaptive delay in ms (default: `5_000`)
    * `:initial_delay` — delay used before enough samples are collected (default: `100`)
    * `:min_samples` — samples needed before switching from `:initial_delay` to adaptive (default: `10`)
    * `:token_max` — token bucket capacity (default: `10`)
    * `:token_success_credit` — tokens earned per completed request (default: `0.1`)
    * `:token_hedge_cost` — tokens spent when a hedge fires (default: `1.0`)
    * `:token_threshold` — minimum tokens required to allow hedging (default: `1.0`)
  """
  use GenServer

  alias Resiliency.Hedged.Percentile

  defstruct [
    :percentile_target,
    :min_delay,
    :max_delay,
    :initial_delay,
    :min_samples,
    :token_max,
    :token_success_credit,
    :token_hedge_cost,
    :token_threshold,
    tokens: 10.0,
    buffer: %Percentile{},
    stats: %{total_requests: 0, hedged_requests: 0, hedge_won: 0}
  ]

  @typedoc "Internal state of the tracker GenServer."
  @type t :: %__MODULE__{}

  # --- Client API ---

  @doc """
  Starts a tracker process linked to the caller.

  Requires a `:name` option. See module documentation for all options.

  ## Parameters

  * `opts` -- keyword list of options. See the module documentation for the full list. The `:name` option is required.

  ## Returns

  `{:ok, pid}` on success, or `{:error, reason}` if the process cannot be started.

  ## Raises

  Raises `KeyError` if the required `:name` option is not provided.

  ## Examples

      {:ok, _pid} = Resiliency.Hedged.Tracker.start_link(name: MyTracker)

      Resiliency.Hedged.Tracker.start_link(name: MyTracker, percentile: 99, min_delay: 5)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns `{delay_ms, allow_hedge?}` based on current adaptive state.

  The delay is the configured percentile of recent latency samples, clamped
  to `[min_delay, max_delay]`. Before `:min_samples` observations are
  recorded, `:initial_delay` is returned instead.

  Hedging is allowed when the token bucket has at least `:token_threshold`
  tokens remaining.

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.Hedged.Tracker` process.

  ## Returns

  A tuple `{delay_ms, allow_hedge?}` where `delay_ms` is a non-negative integer representing the adaptive delay in milliseconds, and `allow_hedge?` is a boolean indicating whether the token bucket permits hedging.
  """
  @spec get_config(GenServer.server()) :: {non_neg_integer(), boolean()}
  def get_config(server) do
    GenServer.call(server, :get_config)
  end

  @doc """
  Records an observation after a request completes.

  Expects a map with the following keys:

    * `:latency_ms` — end-to-end latency of the winning response in milliseconds
    * `:hedged?` — whether a hedge request was actually dispatched
    * `:hedge_won?` — whether the hedge (not the original) produced the winning response

  The latency sample feeds the percentile buffer, while `:hedged?` and
  `:hedge_won?` update the token bucket and counters.

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.Hedged.Tracker` process.
  * `observation` -- a map containing `:latency_ms` (number), `:hedged?` (boolean), and `:hedge_won?` (boolean).

  ## Returns

  `:ok`. The observation is processed asynchronously via `GenServer.cast/2`.
  """
  @spec record(GenServer.server(), map()) :: :ok
  def record(server, observation) do
    GenServer.cast(server, {:record, observation})
  end

  @doc """
  Returns current stats including counters, percentiles, delay, and tokens.

  The returned map contains:

    * `:total_requests` — number of observations recorded
    * `:hedged_requests` — number of observations where a hedge fired
    * `:hedge_won` — number of times the hedge beat the original
    * `:p50`, `:p95`, `:p99` — latency percentiles from the sample buffer
    * `:current_delay` — adaptive delay that would be returned by `get_config/1`
    * `:tokens` — current token bucket level

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.Hedged.Tracker` process.

  ## Returns

  A map with keys `:total_requests`, `:hedged_requests`, `:hedge_won`, `:p50`, `:p95`, `:p99`, `:current_delay`, and `:tokens`.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, 1000)
    token_max = Keyword.get(opts, :token_max, 10)

    state = %__MODULE__{
      percentile_target: Keyword.get(opts, :percentile, 95),
      min_delay: Keyword.get(opts, :min_delay, 1),
      max_delay: Keyword.get(opts, :max_delay, 5_000),
      initial_delay: Keyword.get(opts, :initial_delay, 100),
      min_samples: Keyword.get(opts, :min_samples, 10),
      token_max: token_max,
      token_success_credit: Keyword.get(opts, :token_success_credit, 0.1),
      token_hedge_cost: Keyword.get(opts, :token_hedge_cost, 1.0),
      token_threshold: Keyword.get(opts, :token_threshold, 1.0),
      tokens: token_max + 0.0,
      buffer: Percentile.new(buffer_size)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    delay = compute_delay(state)
    allow_hedge? = state.tokens >= state.token_threshold
    {:reply, {delay, allow_hedge?}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        p50: Percentile.query(state.buffer, 50),
        p95: Percentile.query(state.buffer, 95),
        p99: Percentile.query(state.buffer, 99),
        current_delay: compute_delay(state),
        tokens: state.tokens
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:record, observation}, state) do
    buffer = Percentile.add(state.buffer, observation.latency_ms)

    # Update token bucket
    tokens = state.tokens + state.token_success_credit
    tokens = if observation.hedged?, do: tokens - state.token_hedge_cost, else: tokens
    tokens = clamp(tokens, 0.0, state.token_max)

    # Update stats
    stats = %{
      state.stats
      | total_requests: state.stats.total_requests + 1,
        hedged_requests: state.stats.hedged_requests + if(observation.hedged?, do: 1, else: 0),
        hedge_won: state.stats.hedge_won + if(observation.hedge_won?, do: 1, else: 0)
    }

    {:noreply, %{state | buffer: buffer, tokens: tokens, stats: stats}}
  end

  # --- Private helpers ---

  defp compute_delay(state) do
    if state.buffer.size > 0 and state.buffer.size >= state.min_samples do
      state.buffer
      |> Percentile.query(state.percentile_target)
      |> clamp(state.min_delay, state.max_delay)
      |> round()
    else
      state.initial_delay
    end
  end

  defp clamp(value, min_val, max_val) do
    value |> max(min_val) |> min(max_val)
  end
end
