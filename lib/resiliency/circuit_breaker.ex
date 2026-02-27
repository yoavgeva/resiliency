defmodule Resiliency.CircuitBreaker do
  @moduledoc """
  A circuit breaker with sliding window failure-rate tracking and automatic recovery.

  A circuit breaker wraps calls to a downstream service and monitors their
  outcomes. When the failure rate exceeds a threshold, the circuit "trips"
  to the `:open` state, rejecting calls immediately without contacting the
  downstream. After a configurable timeout, the circuit moves to `:half_open`
  and allows a small number of probe calls through. If the probes succeed,
  the circuit closes and traffic resumes. If they fail, the circuit reopens.

  Inspired by [Resilience4j](https://resilience4j.readme.io/docs/circuitbreaker)
  and [gobreaker](https://github.com/sony/gobreaker), with an Elixir-idiomatic
  API that follows the conventions of this library.

  ## When to use

    * Your downstream service experiences periodic outages and you want to
      stop calling it until it recovers -- avoiding wasted resources and
      cascading failures.
    * You need automatic recovery: after a cool-down period, probe calls
      verify the downstream is healthy before resuming full traffic.
    * You want failure-rate-based tripping (not just consecutive failures)
      with a sliding window that forgets old outcomes naturally.
    * You need slow call detection: calls that succeed but take too long
      can trip the circuit just like failures.

  ## Quick start

      # 1. Add to your supervision tree
      children = [
        {Resiliency.CircuitBreaker, name: MyApp.Breaker, failure_rate_threshold: 0.5}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # 2. Use it
      case Resiliency.CircuitBreaker.call(MyApp.Breaker, fn -> HttpClient.get(url) end) do
        {:ok, response} -> handle_response(response)
        {:error, :circuit_open} -> {:error, :service_degraded}
        {:error, reason} -> {:error, reason}
      end

  ## How it works

  The circuit breaker runs as a `GenServer` that maintains state and failure
  rates. The protected function runs in the **caller's process**, not inside
  the GenServer. This means:

    * The GenServer is never blocked by slow downstream calls.
    * A crash in the protected function does not crash the GenServer.
    * Permission checks are synchronous (`GenServer.call`), but recording
      outcomes is asynchronous (`GenServer.cast`) for minimal overhead.

  ## States

  The circuit breaker has three states:

    * **`:closed`** -- Normal operation. Calls are allowed through. Outcomes
      are recorded in a count-based sliding window. When the failure rate
      (or slow call rate) exceeds the configured threshold and the minimum
      number of calls has been reached, the circuit transitions to `:open`.

    * **`:open`** -- Calls are rejected immediately with `{:error, :circuit_open}`.
      After `open_timeout` milliseconds, the circuit transitions to `:half_open`.

    * **`:half_open`** -- A limited number of probe calls are allowed through
      (controlled by `permitted_calls_in_half_open`). If the probes succeed
      (failure rate stays below threshold), the circuit transitions back to
      `:closed`. If any probe fails above the threshold, it transitions back
      to `:open`.

  ## Return values

  | Function | Success | Circuit open | fn crashes |
  |---|---|---|---|
  | `call/2,3` | `{:ok, result}` | `{:error, :circuit_open}` | `{:error, reason}` |
  | `allow/1` | `{:ok, record_fn}` | `{:error, :circuit_open}` | N/A |

  ## Error handling

  If the function raises, exits, or throws, the error is caught and returned
  as `{:error, reason}`. The outcome is classified using `should_record` and
  recorded to the sliding window.

      {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
        Resiliency.CircuitBreaker.call(MyApp.Breaker, fn -> raise "boom" end)

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `call/2,3` | O(1) GenServer call + O(1) GenServer cast + O(f) function | O(w) — sliding window of size w |
  | `allow/1` | O(1) GenServer call | O(1) |
  | `get_state/1` | O(1) | O(1) |
  | `get_stats/1` | O(1) | O(1) |
  | `reset/1` | O(w) — reallocates window | O(w) |
  | `force_open/1` | O(1) | O(1) |
  | `force_close/1` | O(w) — resets window | O(w) |
  """

  @typedoc "A circuit breaker reference — a registered name, PID, or `{:via, ...}` tuple."
  @type name :: GenServer.server()

  @doc """
  Returns a child specification for starting under a supervisor.

  ## Options

  * `:name` -- (required) the name to register the circuit breaker under.
  * `:window_size` -- number of call outcomes in the sliding window. Default `100`.
  * `:failure_rate_threshold` -- failure rate (0.0–1.0) that trips the circuit. Default `0.5`.
  * `:slow_call_threshold` -- duration in ms above which a call is "slow". Default `:infinity` (disabled).
  * `:slow_call_rate_threshold` -- slow call rate (0.0–1.0) that trips the circuit. Default `1.0`.
  * `:open_timeout` -- ms before `:open` → `:half_open`. Default `60_000`.
  * `:permitted_calls_in_half_open` -- probe calls allowed in `:half_open`. Default `1`.
  * `:minimum_calls` -- min recorded calls before evaluating failure rate. Default `10`.
  * `:should_record` -- `fn result -> :success | :failure | :ignore` classification function.
  * `:on_state_change` -- `fn name, from_state, to_state -> any` callback.

  ## Examples

      children = [
        {Resiliency.CircuitBreaker, name: MyApp.Breaker, failure_rate_threshold: 0.5}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      iex> spec = Resiliency.CircuitBreaker.child_spec(name: :my_cb)
      iex> spec.id
      {Resiliency.CircuitBreaker, :my_cb}

  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {Resiliency.CircuitBreaker.Server, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts a circuit breaker linked to the current process.

  Typically you'd use `child_spec/1` instead to start under a supervisor.
  See `child_spec/1` for options.

  ## Examples

      {:ok, pid} = Resiliency.CircuitBreaker.start_link(name: MyApp.Breaker)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Resiliency.CircuitBreaker.Server.start_link(opts)
  end

  @doc """
  Executes `fun` through the circuit breaker.

  If the circuit is `:closed` or `:half_open` (with available permits), the
  function runs in the caller's process. The result is classified using the
  configured `should_record` function and recorded asynchronously.

  If the circuit is `:open`, returns `{:error, :circuit_open}` immediately
  without executing `fun`.

  ## Parameters

  * `name` -- the name or PID of a running circuit breaker.
  * `fun` -- a zero-arity function to execute.
  * `opts` -- optional keyword list. Currently unused, reserved for future options.

  ## Returns

  `{:ok, result}` on success, `{:error, :circuit_open}` when the circuit is
  open, or `{:error, reason}` if the function raises, exits, or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :call_cb)
      iex> Resiliency.CircuitBreaker.call(:call_cb, fn -> {:ok, 42} end)
      {:ok, {:ok, 42}}

  """
  @spec call(name(), (-> result)) :: {:ok, result} | {:error, term()} when result: term()
  @spec call(name(), (-> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: term()
  def call(name, fun, _opts \\ []) when is_function(fun, 0) do
    case GenServer.call(name, :check_permission) do
      {:error, :circuit_open} ->
        {:error, :circuit_open}

      {:ok, should_record} ->
        start = System.monotonic_time(:millisecond)

        {raw_result, error_result} = execute(fun)

        duration_ms = System.monotonic_time(:millisecond) - start
        outcome = classify(should_record, raw_result)

        case outcome do
          :ignore ->
            GenServer.cast(name, :release_permit)

          outcome when outcome in [:success, :failure] ->
            GenServer.cast(name, {:record, outcome, duration_ms})
        end

        case error_result do
          nil -> {:ok, raw_result}
          err -> {:error, err}
        end
    end
  end

  @doc """
  Two-step API: check permission and get a recording function.

  This is useful when you cannot wrap the operation in a zero-arity function
  (e.g., the work spans multiple process messages or external systems).

  If the circuit allows the call, returns `{:ok, record_fn}` where `record_fn`
  is a function that accepts `:success`, `:failure`, or `:ignore` and records
  the outcome. The record function is **one-shot** — only the first call takes
  effect; subsequent calls are silent no-ops.

  If the caller process dies before calling `record_fn`, the permit is
  automatically released as a `:failure`. This prevents permits from being
  permanently leaked when callers crash.

  ## Parameters

  * `name` -- the name or PID of a running circuit breaker.

  ## Returns

  `{:ok, record_fn}` when the circuit allows the call, or
  `{:error, :circuit_open}` when the circuit is open.

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :allow_cb)
      iex> {:ok, record} = Resiliency.CircuitBreaker.allow(:allow_cb)
      iex> record.(:success)
      :ok

  """
  @spec allow(name()) :: {:ok, (atom() -> :ok)} | {:error, :circuit_open}
  def allow(name) do
    case GenServer.call(name, :check_permission_monitored) do
      {:error, :circuit_open} ->
        {:error, :circuit_open}

      {:ok, _should_record, monitor_ref} ->
        record = once_record(name, monitor_ref)
        {:ok, record}
    end
  end

  @doc """
  Returns the current state of the circuit breaker.

  ## Returns

  `:closed`, `:open`, or `:half_open`.

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :state_cb)
      iex> Resiliency.CircuitBreaker.get_state(:state_cb)
      :closed

  """
  @spec get_state(name()) :: :closed | :open | :half_open
  def get_state(name) do
    GenServer.call(name, :get_state)
  end

  @doc """
  Returns statistics about the circuit breaker.

  ## Returns

  A map containing:
  * `:state` -- the current state (`:closed`, `:open`, or `:half_open`)
  * `:total` -- total recorded calls in the sliding window
  * `:failures` -- number of recorded failures
  * `:slow_calls` -- number of recorded slow calls
  * `:failure_rate` -- current failure rate (0.0–1.0)
  * `:slow_call_rate` -- current slow call rate (0.0–1.0)

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :stats_cb)
      iex> stats = Resiliency.CircuitBreaker.get_stats(:stats_cb)
      iex> stats.state
      :closed
      iex> stats.total
      0

  """
  @spec get_stats(name()) :: map()
  def get_stats(name) do
    GenServer.call(name, :get_stats)
  end

  @doc """
  Resets the circuit breaker to its initial state.

  Clears the sliding window, cancels any open timeout timer, and transitions
  to `:closed`.

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :reset_cb)
      iex> Resiliency.CircuitBreaker.reset(:reset_cb)
      :ok

  """
  @spec reset(name()) :: :ok
  def reset(name) do
    GenServer.call(name, :reset)
  end

  @doc """
  Forces the circuit to the `:open` state.

  The circuit stays open until `reset/1` or `force_close/1` is called.
  No automatic `:open` → `:half_open` timer is started.

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :fo_cb)
      iex> Resiliency.CircuitBreaker.force_open(:fo_cb)
      :ok
      iex> Resiliency.CircuitBreaker.get_state(:fo_cb)
      :open

  """
  @spec force_open(name()) :: :ok
  def force_open(name) do
    GenServer.call(name, :force_open)
  end

  @doc """
  Forces the circuit to the `:closed` state.

  Resets the sliding window and clears any timers.

  ## Examples

      iex> {:ok, _pid} = Resiliency.CircuitBreaker.start_link(name: :fc_cb)
      iex> Resiliency.CircuitBreaker.force_open(:fc_cb)
      :ok
      iex> Resiliency.CircuitBreaker.force_close(:fc_cb)
      :ok
      iex> Resiliency.CircuitBreaker.get_state(:fc_cb)
      :closed

  """
  @spec force_close(name()) :: :ok
  def force_close(name) do
    GenServer.call(name, :force_close)
  end

  # Builds a one-shot record function for allow/1. Uses :atomics to ensure
  # only the first call takes effect — subsequent calls are silent no-ops.
  # Sends a demonitor cast to clean up the caller monitor.
  defp once_record(name, monitor_ref) do
    ref = :atomics.new(1, signed: false)

    fn outcome when outcome in [:success, :failure, :ignore] ->
      if :atomics.compare_exchange(ref, 1, 0, 1) == :ok do
        GenServer.cast(name, {:demonitor_permit, monitor_ref})
        cast_outcome(name, outcome)
      end

      :ok
    end
  end

  defp cast_outcome(name, :ignore), do: GenServer.cast(name, :release_permit)
  defp cast_outcome(name, outcome), do: GenServer.cast(name, {:record, outcome, 0})

  # Invokes the should_record classifier safely. If it crashes or returns an
  # invalid value, falls back to :success to avoid penalising the downstream
  # for a misconfigured classifier and to prevent permit leaks.
  defp classify(should_record, raw_result) do
    case should_record.(raw_result) do
      outcome when outcome in [:success, :failure, :ignore] -> outcome
      _bad -> :success
    end
  rescue
    _ -> :success
  catch
    _, _ -> :success
  end

  # Executes the function with rescue/catch, returning {raw_result, error_info}.
  # error_info is nil on success, or the error tuple on failure.
  defp execute(fun) do
    result = fun.()
    {result, nil}
  rescue
    e ->
      {{:error, {e, __STACKTRACE__}}, {e, __STACKTRACE__}}
  catch
    :exit, reason ->
      {{:error, reason}, reason}

    :throw, value ->
      {{:error, {:nocatch, value}}, {:nocatch, value}}
  end
end
