defmodule Resiliency.Hedged do
  @moduledoc """
  Hedged requests for Elixir.

  Fire a backup request after a delay, take whichever finishes first, cancel
  the rest. A tail-latency optimization inspired by Google's "Tail at Scale"
  paper.

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

  ## Examples

      iex> Resiliency.Hedged.run(fn -> {:ok, 42} end)
      {:ok, 42}

      iex> Resiliency.Hedged.run(fn -> :hello end)
      {:ok, :hello}

      iex> Resiliency.Hedged.run(fn -> {:error, :boom} end, max_requests: 1)
      {:error, :boom}

  """
  @spec run((-> any()), [option()]) :: {:ok, any()} | {:error, any()}
  def run(fun, opts \\ [])

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

  @doc """
  Executes `fun` with adaptive hedging controlled by a `Resiliency.Hedged.Tracker`.

  The tracker determines the delay based on observed latency percentiles
  and controls hedge rate via a token bucket.

  Returns `{:ok, result}` or `{:error, reason}`.

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

  ## Options

    * `:name` — required, the registered name for the tracker
    * `:percentile` — target percentile for adaptive delay (default: `95`)
    * `:buffer_size` — max latency samples to keep (default: `1000`)
    * `:min_delay` — floor for adaptive delay in ms (default: `1`)
    * `:max_delay` — ceiling for adaptive delay in ms (default: `5_000`)
    * `:initial_delay` — delay before enough samples collected (default: `100`)
    * `:min_samples` — samples needed before adapting (default: `10`)
    * `:token_max` — token bucket capacity (default: `10`)
    * `:token_success_credit` — tokens earned per request (default: `0.1`)
    * `:token_hedge_cost` — tokens spent per hedge (default: `1.0`)
    * `:token_threshold` — min tokens to allow hedging (default: `1.0`)

  """
  @spec start_link([tracker_option()]) :: GenServer.on_start()
  def start_link(opts) do
    Resiliency.Hedged.Tracker.start_link(opts)
  end

  @doc """
  Returns a child specification for use in a supervision tree.

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
