defmodule Resiliency.Hedged do
  @moduledoc """
  Hedged requests for Elixir.

  Fire a backup request after a delay, take whichever finishes first, cancel
  the rest. A tail-latency optimization inspired by Google's "Tail at Scale"
  paper.

  ## When to use

    * Querying a latency-sensitive datastore (e.g., a key-value cache or search
      index) where occasional slow responses are caused by GC pauses, network
      jitter, or cold replicas — a hedge cuts tail latency dramatically.
    * Calling a replicated service behind a load balancer where individual
      instances sometimes stall — firing a second request to a different
      instance lets the fast replica win.
    * Performing DNS or geo-routing lookups where the first resolver may be
      slow but a redundant resolver responds quickly — hedge to keep p99
      tight.
    * Any read-only or idempotent operation where issuing a duplicate request
      is cheap relative to the cost of waiting for a slow primary.

  ## How it works

  When you call `run/2` (stateless mode), the engine spawns the first request
  immediately. After `:delay` milliseconds — or sooner if the first request
  fails and the failure matches the `:non_fatal` predicate — a second copy of
  the same function is spawned. This continues until either a request succeeds,
  `:max_requests` copies have been launched, or the overall `:timeout` expires.
  The first successful response is returned and all remaining in-flight tasks
  are killed, freeing resources.

  The idea comes from Google's 2013 paper "The Tail at Scale" by Jeffrey Dean
  and Luiz Andre Barroso. The paper observes that even when individual request
  latency is fast at the median, high-percentile latency can be orders of
  magnitude worse. By sending a redundant request after a short delay — chosen
  to be around the expected latency percentile — you effectively "race" two
  independent samples of the latency distribution. The probability that both
  are slow is the product of two small probabilities, so tail latency drops
  significantly at the cost of a modest increase in total load.

  In adaptive mode (`run/3` with a tracker), the delay is not fixed — it is
  computed as a configurable percentile of recently observed latencies (see
  `Resiliency.Hedged.Tracker`). A token-bucket mechanism throttles the hedge
  rate: each completed request earns a small credit, and each hedge spends a
  larger cost. When the bucket runs dry, hedging is temporarily disabled,
  preventing runaway fan-out under sustained load.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `run/2` (stateless) | O(m) where m = `max_requests` — each hedge spawn is O(1) | O(m) — one monitored process per hedge |
  | `run/3` (adaptive) | O(m) plus O(1) GenServer call to the tracker | O(m) |
  | `start_link/1` | O(1) | O(1) |
  | `child_spec/1` | O(1) | O(1) |

  ## Quick start

      # Stateless — fixed delay
      {:ok, body} = Resiliency.Hedged.run(fn -> fetch(url) end, delay: 100)

      # Adaptive — delay auto-tunes from observed latency
      {:ok, _} = Resiliency.Hedged.start_link(name: MyHedge)
      {:ok, body} = Resiliency.Hedged.run(MyHedge, fn -> fetch(url) end)

  ## Stateless options

    * `:delay` — ms before firing the next hedge (default: `100`)
    * `:max_requests` — total concurrent attempts (default: `2`)
    * `:timeout` — overall deadline in ms (default: `5_000`)
    * `:non_fatal` — `fn reason -> boolean` predicate; when true, fires the
      next hedge immediately instead of waiting for the delay (default:
      `fn _ -> false end`)
    * `:on_hedge` — `fn attempt -> any` callback invoked before each hedge
    * `:now_fn` — injectable clock `fn :millisecond -> integer` for testing

  ## Result normalization

    * `{:ok, value}` — success
    * `{:error, reason}` — failure
    * bare value — wrapped as `{:ok, value}`
    * `:ok` — `{:ok, :ok}`
    * `:error` — `{:error, :error}`
    * raise / exit / throw — captured, treated as failure

  """

  @typedoc "Options for stateless `run/2`."
  @type option ::
          {:delay, non_neg_integer()}
          | {:max_requests, pos_integer()}
          | {:timeout, pos_integer()}
          | {:non_fatal, (any() -> boolean())}
          | {:on_hedge, (pos_integer() -> any()) | nil}
          | {:now_fn, (:millisecond -> integer())}

  @typedoc "Options for `start_link/1` and `child_spec/1`."
  @type tracker_option ::
          {:name, GenServer.name()}
          | {:percentile, number()}
          | {:buffer_size, pos_integer()}
          | {:min_delay, non_neg_integer()}
          | {:max_delay, pos_integer()}
          | {:initial_delay, non_neg_integer()}
          | {:min_samples, non_neg_integer()}
          | {:token_max, number()}
          | {:token_success_credit, number()}
          | {:token_hedge_cost, number()}
          | {:token_threshold, number()}

  @doc """
  Executes `fun` with hedging using a fixed delay.

  Returns `{:ok, result}` or `{:error, reason}`.

  ## Parameters

  * `fun` -- a zero-arity function to execute. Results are normalized (see "Result normalization" in the module docs).
  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:delay` -- milliseconds before firing the next hedge. Defaults to `100`.
    * `:max_requests` -- total concurrent attempts. Defaults to `2`.
    * `:timeout` -- overall deadline in milliseconds. Defaults to `5_000`.
    * `:non_fatal` -- `fn reason -> boolean` predicate; when `true`, fires the next hedge immediately instead of waiting for the delay. Defaults to `fn _ -> false end`.
    * `:on_hedge` -- `fn attempt -> any` callback invoked before each hedge. Defaults to `nil`.
    * `:now_fn` -- injectable clock `fn :millisecond -> integer` for testing. Defaults to `&System.monotonic_time/1`.

  ## Returns

  `{:ok, result}` from the first function invocation that completes successfully, or `{:error, reason}` if all attempts fail.

  ## Examples

      iex> Resiliency.Hedged.run(fn -> {:ok, 42} end)
      {:ok, 42}

      iex> Resiliency.Hedged.run(fn -> :hello end)
      {:ok, :hello}

      iex> Resiliency.Hedged.run(fn -> {:error, :boom} end, max_requests: 1)
      {:error, :boom}

  """
  @spec run((-> any()), [option()]) :: {:ok, any()} | {:error, any()}
  def run(fun) when is_function(fun, 0), do: run(fun, [])

  def run(fun, opts) when is_function(fun, 0) and is_list(opts) do
    runner_opts = [
      delay: Keyword.get(opts, :delay, 100),
      max_requests: Keyword.get(opts, :max_requests, 2),
      timeout: Keyword.get(opts, :timeout, 5_000),
      non_fatal: Keyword.get(opts, :non_fatal, fn _ -> false end),
      on_hedge: Keyword.get(opts, :on_hedge),
      now_fn: Keyword.get(opts, :now_fn, &System.monotonic_time/1)
    ]

    case Resiliency.Hedged.Runner.execute(fun, runner_opts) do
      {:ok, value, _meta} -> {:ok, value}
      {:error, reason, _meta} -> {:error, reason}
    end
  end

  def run(server, fun) when (is_atom(server) or is_pid(server)) and is_function(fun, 0) do
    run(server, fun, [])
  end

  @doc """
  Executes `fun` with adaptive hedging controlled by a `Resiliency.Hedged.Tracker`.

  The tracker determines the delay based on observed latency percentiles
  and controls hedge rate via a token bucket.

  Returns `{:ok, result}` or `{:error, reason}`.

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.Hedged.Tracker` process.
  * `fun` -- a zero-arity function to execute. Results are normalized (see "Result normalization" in the module docs).
  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:max_requests` -- total concurrent attempts. Defaults to `2`. Automatically set to `1` when the tracker's token bucket disallows hedging.
    * `:timeout` -- overall deadline in milliseconds. Defaults to `5_000`.
    * `:non_fatal` -- `fn reason -> boolean` predicate; when `true`, fires the next hedge immediately. Defaults to `fn _ -> false end`.
    * `:on_hedge` -- `fn attempt -> any` callback invoked before each hedge. Defaults to `nil`.
    * `:now_fn` -- injectable clock `fn :millisecond -> integer` for testing. Defaults to `&System.monotonic_time/1`.

  ## Returns

  `{:ok, result}` from the first function invocation that completes successfully, or `{:error, reason}` if all attempts fail.

  ## Examples

      {:ok, _} = Resiliency.Hedged.start_link(name: MyHedge)
      {:ok, body} = Resiliency.Hedged.run(MyHedge, fn -> fetch(url) end)

  """
  @spec run(GenServer.server(), (-> any()), [option()]) :: {:ok, any()} | {:error, any()}
  def run(server, fun, opts) when is_function(fun, 0) and is_list(opts) do
    {delay, allow_hedge?} = Resiliency.Hedged.Tracker.get_config(server)
    now_fn = Keyword.get(opts, :now_fn, &System.monotonic_time/1)

    max_requests =
      if allow_hedge?,
        do: Keyword.get(opts, :max_requests, 2),
        else: 1

    runner_opts = [
      delay: delay,
      max_requests: max_requests,
      timeout: Keyword.get(opts, :timeout, 5_000),
      non_fatal: Keyword.get(opts, :non_fatal, fn _ -> false end),
      on_hedge: Keyword.get(opts, :on_hedge),
      now_fn: now_fn
    ]

    start_time = now_fn.(:millisecond)

    case Resiliency.Hedged.Runner.execute(fun, runner_opts) do
      {:ok, value, meta} ->
        latency_ms = now_fn.(:millisecond) - start_time

        Resiliency.Hedged.Tracker.record(server, %{
          latency_ms: latency_ms,
          hedged?: meta.dispatched > 1,
          hedge_won?: meta.winner_index != nil and meta.winner_index > 0
        })

        {:ok, value}

      {:error, reason, meta} ->
        latency_ms = now_fn.(:millisecond) - start_time

        Resiliency.Hedged.Tracker.record(server, %{
          latency_ms: latency_ms,
          hedged?: meta.dispatched > 1,
          hedge_won?: false
        })

        {:error, reason}
    end
  end

  @doc """
  Starts a `Resiliency.Hedged.Tracker` process linked to the current process.

  ## Parameters

  * `opts` -- keyword list of options.
    * `:name` -- (required) the registered name for the tracker process.
    * `:percentile` -- target percentile for adaptive delay. Defaults to `95`.
    * `:buffer_size` -- max latency samples to keep. Defaults to `1000`.
    * `:min_delay` -- floor for adaptive delay in milliseconds. Defaults to `1`.
    * `:max_delay` -- ceiling for adaptive delay in milliseconds. Defaults to `5_000`.
    * `:initial_delay` -- delay used before enough samples are collected. Defaults to `100`.
    * `:min_samples` -- samples needed before switching to adaptive delay. Defaults to `10`.
    * `:token_max` -- token bucket capacity. Defaults to `10`.
    * `:token_success_credit` -- tokens earned per completed request. Defaults to `0.1`.
    * `:token_hedge_cost` -- tokens spent when a hedge fires. Defaults to `1.0`.
    * `:token_threshold` -- minimum tokens required to allow hedging. Defaults to `1.0`.

  ## Returns

  `{:ok, pid}` on success, or `{:error, reason}` if the process cannot be started.

  ## Raises

  Raises `KeyError` if the required `:name` option is not provided.
  """
  @spec start_link([tracker_option()]) :: GenServer.on_start()
  def start_link(opts) do
    Resiliency.Hedged.Tracker.start_link(opts)
  end

  @doc """
  Returns a child specification for use in a supervision tree.

  ## Parameters

  * `opts` -- keyword list of tracker options (same as `start_link/1`). The `:name` option is required.

  ## Returns

  A `Supervisor.child_spec()` map suitable for inclusion in a supervision tree.

  ## Example

      children = [
        {Resiliency.Hedged, name: MyHedge, percentile: 99}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  """
  @spec child_spec([tracker_option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end
