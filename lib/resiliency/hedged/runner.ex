defmodule Resiliency.Hedged.Runner do
  @moduledoc false

  # Core hedging engine. Fires staggered requests using spawn_monitor,
  # takes the first success, and shuts down the rest.

  @type meta :: %{dispatched: pos_integer(), winner_index: non_neg_integer() | nil}

  @spec execute((-> any()), keyword()) ::
          {:ok, any(), meta()} | {:error, any(), meta()}
  def execute(fun, opts) do
    delay = Keyword.fetch!(opts, :delay)
    max_requests = Keyword.fetch!(opts, :max_requests)
    timeout = Keyword.fetch!(opts, :timeout)
    non_fatal = Keyword.get(opts, :non_fatal, fn _ -> false end)
    on_hedge = Keyword.get(opts, :on_hedge)
    now_fn = Keyword.get(opts, :now_fn, &System.monotonic_time/1)

    deadline = now_fn.(:millisecond) + timeout

    run_loop(fun, delay, max_requests, non_fatal, on_hedge, now_fn, deadline)
  end

  defp run_loop(fun, delay, max_requests, non_fatal, on_hedge, now_fn, deadline) do
    # Fire first request
    task1 = fire(fun)
    tasks = %{task1.ref => {task1, 0}}

    state = %{
      tasks: tasks,
      dispatched: 1,
      max_requests: max_requests,
      delay: delay,
      non_fatal: non_fatal,
      on_hedge: on_hedge,
      now_fn: now_fn,
      deadline: deadline,
      fun: fun,
      last_error: nil,
      pending: 1
    }

    receive_loop(state)
  end

  # All pending tasks completed/failed and no more hedges to fire
  defp receive_loop(%{pending: 0, dispatched: d, max_requests: max} = state) when d >= max do
    {:error, state.last_error, %{dispatched: state.dispatched, winner_index: nil}}
  end

  # All pending tasks completed/failed but we can still fire hedges
  defp receive_loop(%{pending: 0} = state) do
    fire_hedge(state)
  end

  defp receive_loop(state) do
    remaining_ms = max(state.deadline - state.now_fn.(:millisecond), 0)
    wait_ms = min(state.delay, remaining_ms)

    receive do
      {ref, result} when is_map_key(state.tasks, ref) ->
        Process.demonitor(ref, [:flush])
        {_task, index} = state.tasks[ref]

        case normalize(result) do
          {:ok, value} ->
            shutdown_others(state, ref)
            {:ok, value, %{dispatched: state.dispatched, winner_index: index}}

          {:error, reason} ->
            state = %{
              state
              | tasks: Map.delete(state.tasks, ref),
                pending: state.pending - 1,
                last_error: reason
            }

            if state.non_fatal.(reason) do
              # Non-fatal: immediately fire next hedge (fast-forward)
              maybe_fire_hedge(state)
            else
              receive_loop(state)
            end
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.tasks, ref) ->
        error_reason =
          case reason do
            :normal -> state.last_error
            other -> other
          end

        state = %{
          state
          | tasks: Map.delete(state.tasks, ref),
            pending: state.pending - 1,
            last_error: error_reason || state.last_error
        }

        receive_loop(state)
    after
      wait_ms ->
        if state.now_fn.(:millisecond) >= state.deadline do
          shutdown_all(state)
          {:error, :timeout, %{dispatched: state.dispatched, winner_index: nil}}
        else
          maybe_fire_hedge(state)
        end
    end
  end

  defp maybe_fire_hedge(state) do
    if state.dispatched < state.max_requests do
      fire_hedge(state)
    else
      receive_loop(state)
    end
  end

  defp fire_hedge(state) do
    if state.on_hedge, do: state.on_hedge.(state.dispatched + 1)
    task = fire(state.fun)
    index = state.dispatched

    state = %{
      state
      | tasks: Map.put(state.tasks, task.ref, {task, index}),
        dispatched: state.dispatched + 1,
        pending: state.pending + 1
    }

    receive_loop(state)
  end

  defp fire(fun) do
    caller = self()
    owner_ref = make_ref()

    pid =
      spawn(fn ->
        mref =
          receive do
            {^owner_ref, mref} -> mref
          end

        try do
          result = fun.()
          send(caller, {mref, result})
        rescue
          e ->
            exit({e, __STACKTRACE__})
        catch
          :exit, reason ->
            exit(reason)

          :throw, value ->
            exit({{:nocatch, value}, __STACKTRACE__})
        end
      end)

    mref = Process.monitor(pid)
    send(pid, {owner_ref, mref})
    %{pid: pid, ref: mref}
  end

  defp normalize({:ok, value}), do: {:ok, value}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(:ok), do: {:ok, :ok}
  defp normalize(:error), do: {:error, :error}
  defp normalize(value), do: {:ok, value}

  defp shutdown_others(state, winner_ref) do
    for {ref, {task, _index}} <- state.tasks, ref != winner_ref do
      Process.demonitor(ref, [:flush])
      Process.exit(task.pid, :kill)
    end
  end

  defp shutdown_all(state) do
    for {ref, {task, _index}} <- state.tasks do
      Process.demonitor(ref, [:flush])
      Process.exit(task.pid, :kill)
    end
  end
end
