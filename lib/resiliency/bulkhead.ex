defmodule Resiliency.Bulkhead do
  @moduledoc """
  A bulkhead for isolating workloads with per-partition concurrency limits.

  A bulkhead wraps calls to a downstream service and limits how many can
  execute concurrently. When the limit is reached, callers are either
  rejected immediately or queued for a configurable wait time. This
  prevents one slow or overloaded service from consuming all available
  resources and cascading into other parts of the system.

  Inspired by [Resilience4j's SemaphoreBulkhead](https://resilience4j.readme.io/docs/bulkhead),
  with an Elixir-idiomatic API that follows the conventions of this library.

  ## When to use

    * You need to isolate different workloads so that a spike in one does
      not starve others — e.g., separate bulkheads for search, payments,
      and notifications.
    * You want to cap the number of concurrent calls to a downstream
      service, with clear rejection semantics when the limit is reached.
    * You need server-managed wait queues with configurable timeouts and
      FIFO fairness, rather than caller-side timeouts.

  ## Quick start

      # 1. Add to your supervision tree
      children = [
        {Resiliency.Bulkhead, name: MyApp.ApiBulkhead, max_concurrent: 10}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # 2. Use it
      case Resiliency.Bulkhead.call(MyApp.ApiBulkhead, fn -> HttpClient.get(url) end) do
        {:ok, response} -> handle_response(response)
        {:error, :bulkhead_full} -> {:error, :overloaded}
        {:error, reason} -> {:error, reason}
      end

  ## How it works

  The bulkhead runs as a `GenServer` that tracks active permits and a
  waiter queue. The protected function runs in the **caller's process**,
  not inside the GenServer. This means:

    * The GenServer is never blocked by slow downstream calls.
    * A crash in the protected function does not crash the GenServer.
    * Permit acquisition is synchronous (`GenServer.call`), and permit
      release is asynchronous (`GenServer.cast`) for minimal overhead.

  ## Return values

  | Function | Success | Bulkhead full | fn crashes |
  |---|---|---|---|
  | `call/2,3` | `{:ok, result}` | `{:error, :bulkhead_full}` | `{:error, reason}` |

  ## Error handling

  If the function raises, exits, or throws, the error is caught, the
  permit is released, and the error is returned to the caller:

      {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
        Resiliency.Bulkhead.call(MyApp.ApiBulkhead, fn -> raise "boom" end)

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `call/2,3` | O(1) GenServer call + O(f) function | O(q) — one entry per queued waiter |
  | `get_stats/1` | O(1) | O(1) |
  | `reset/1` | O(q) — rejects all waiters | O(1) |

  ## Telemetry

  All events are emitted in the caller's process. See `Resiliency.Telemetry` for the
  complete event catalogue.

  ### `[:resiliency, :bulkhead, :call, :start]`

  Emitted at the beginning of every `call/2,3` invocation, before the permit request.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `system_time` | `integer` | `System.system_time()` at emission time |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The bulkhead name passed to `call/2,3` |

  ### `[:resiliency, :bulkhead, :call, :rejected]`

  Emitted when the bulkhead queue is full and the call is rejected without executing the function.
  Always followed immediately by a `:stop` event.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | _(none)_ | | |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The bulkhead name |

  ### `[:resiliency, :bulkhead, :call, :permitted]`

  Emitted when the bulkhead grants a permit and the function begins execution.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | _(none)_ | | |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The bulkhead name |

  ### `[:resiliency, :bulkhead, :call, :stop]`

  Emitted after every `call/2,3` completes — whether rejected, successful, or failed.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `duration` | `integer` | Elapsed native time units (`System.monotonic_time/0` delta) |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The bulkhead name |
  | `result` | `:ok \| :error` | `:ok` on success, `:error` on failure or rejection |
  | `error` | `term \| nil` | The error reason, `:bulkhead_full` if rejected, `nil` on success |

  """

  @typedoc "A bulkhead reference — a registered name, PID, or `{:via, ...}` tuple."
  @type name :: GenServer.server()

  @doc """
  Returns a child specification for starting under a supervisor.

  ## Options

  * `:name` -- (required) the name to register the bulkhead under.
  * `:max_concurrent` -- (required) the maximum number of concurrent calls.
    Must be a non-negative integer. `0` rejects all calls (useful as a kill-switch).
  * `:max_wait` -- max time in ms a caller will wait for a permit. `0` means
    reject immediately when full. `:infinity` means wait forever. Default `0`.
  * `:on_call_permitted` -- `fn name -> any` callback fired when a call is permitted.
  * `:on_call_rejected` -- `fn name -> any` callback fired when a call is rejected.
  * `:on_call_finished` -- `fn name -> any` callback fired when a call finishes.

  ## Examples

      children = [
        {Resiliency.Bulkhead, name: MyApp.ApiBulkhead, max_concurrent: 10}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      iex> spec = Resiliency.Bulkhead.child_spec(name: :my_bh, max_concurrent: 5)
      iex> spec.id
      {Resiliency.Bulkhead, :my_bh}

  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {Resiliency.Bulkhead.Server, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts a bulkhead linked to the current process.

  Typically you'd use `child_spec/1` instead to start under a supervisor.
  See `child_spec/1` for options.

  ## Examples

      {:ok, pid} = Resiliency.Bulkhead.start_link(name: MyApp.ApiBulkhead, max_concurrent: 10)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Resiliency.Bulkhead.Server.start_link(opts)
  end

  @doc """
  Executes `fun` through the bulkhead.

  If a permit is available (or becomes available within `max_wait`), the
  function runs in the caller's process. The permit is automatically
  released when the function returns, raises, exits, or throws.

  If no permit is available and the wait time is exhausted, returns
  `{:error, :bulkhead_full}` without executing `fun`.

  ## Parameters

  * `name` -- the name or PID of a running bulkhead.
  * `fun` -- a zero-arity function to execute.
  * `opts` -- optional keyword list.
    * `:max_wait` -- override the server's default `max_wait` for this call.

  ## Returns

  `{:ok, result}` on success, `{:error, :bulkhead_full}` when the bulkhead
  is full and the wait time is exhausted, or `{:error, reason}` if the
  function raises, exits, or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.Bulkhead.start_link(name: :call_bh, max_concurrent: 2)
      iex> Resiliency.Bulkhead.call(:call_bh, fn -> 1 + 1 end)
      {:ok, 2}

  """
  @spec call(name(), (-> result)) :: {:ok, result} | {:error, term()} when result: term()
  @spec call(name(), (-> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: term()
  def call(name, fun, opts \\ []) when is_function(fun, 0) do
    max_wait = Keyword.get(opts, :max_wait)
    validate_max_wait_override!(max_wait)

    telemetry_meta = %{name: name}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:resiliency, :bulkhead, :call, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    case GenServer.call(name, {:acquire, max_wait}, :infinity) do
      {:error, :bulkhead_full} ->
        :telemetry.execute(
          [:resiliency, :bulkhead, :call, :rejected],
          %{},
          telemetry_meta
        )

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:resiliency, :bulkhead, :call, :stop],
          %{duration: duration},
          %{name: name, result: :error, error: :bulkhead_full}
        )

        {:error, :bulkhead_full}

      {:ok, permit_ref} ->
        :telemetry.execute(
          [:resiliency, :bulkhead, :call, :permitted],
          %{},
          telemetry_meta
        )

        {raw_result, error_result} = execute(fun)
        GenServer.cast(name, {:release_permit, permit_ref})

        duration = System.monotonic_time() - start_time

        case error_result do
          nil ->
            :telemetry.execute(
              [:resiliency, :bulkhead, :call, :stop],
              %{duration: duration},
              %{name: name, result: :ok, error: nil}
            )

            {:ok, raw_result}

          err ->
            :telemetry.execute(
              [:resiliency, :bulkhead, :call, :stop],
              %{duration: duration},
              %{name: name, result: :error, error: err}
            )

            {:error, err}
        end
    end
  end

  @doc """
  Returns statistics about the bulkhead.

  ## Returns

  A map containing:
  * `:max_concurrent` -- the configured maximum concurrent calls
  * `:current` -- the number of currently active calls
  * `:available` -- the number of available permits
  * `:waiting` -- the number of callers waiting in the queue

  ## Examples

      iex> {:ok, _pid} = Resiliency.Bulkhead.start_link(name: :stats_bh, max_concurrent: 5)
      iex> stats = Resiliency.Bulkhead.get_stats(:stats_bh)
      iex> stats.max_concurrent
      5
      iex> stats.available
      5

  """
  @spec get_stats(name()) :: map()
  def get_stats(name) do
    GenServer.call(name, :get_stats)
  end

  @doc """
  Resets the bulkhead to its initial state.

  Rejects all waiting callers with `{:error, :bulkhead_full}`, demonitors
  all active permit holders, and sets the current count to 0.

  ## Examples

      iex> {:ok, _pid} = Resiliency.Bulkhead.start_link(name: :reset_bh, max_concurrent: 5)
      iex> Resiliency.Bulkhead.reset(:reset_bh)
      :ok

  """
  @spec reset(name()) :: :ok
  def reset(name) do
    GenServer.call(name, :reset)
  end

  defp validate_max_wait_override!(nil), do: :ok
  defp validate_max_wait_override!(:infinity), do: :ok

  defp validate_max_wait_override!(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_max_wait_override!(value) do
    raise ArgumentError,
          "max_wait must be :infinity or a non-negative integer, got: #{inspect(value)}"
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
