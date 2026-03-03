defmodule Resiliency.Bulkhead.Server do
  @moduledoc false
  use GenServer

  defstruct [
    :name,
    :max_concurrent,
    :max_wait,
    :on_call_permitted,
    :on_call_rejected,
    :on_call_finished,
    current: 0,
    waiters: :queue.new(),
    waiter_count: 0,
    active_monitors: %{}
  ]

  # --- Client ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    validate_opts!(opts)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      max_concurrent: Keyword.fetch!(opts, :max_concurrent),
      max_wait: Keyword.get(opts, :max_wait, 0),
      on_call_permitted: Keyword.get(opts, :on_call_permitted),
      on_call_rejected: Keyword.get(opts, :on_call_rejected),
      on_call_finished: Keyword.get(opts, :on_call_finished)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, max_wait_override}, {pid, _tag} = from, state) do
    effective_max_wait =
      if is_nil(max_wait_override), do: state.max_wait, else: max_wait_override

    cond do
      state.current < state.max_concurrent and :queue.is_empty(state.waiters) ->
        ref = Process.monitor(pid)

        state = %{
          state
          | current: state.current + 1,
            active_monitors: Map.put(state.active_monitors, ref, true)
        }

        fire_callback(state.on_call_permitted, state.name)
        {:reply, {:ok, ref}, state}

      effective_max_wait == 0 or state.max_concurrent == 0 ->
        fire_callback(state.on_call_rejected, state.name)
        {:reply, {:error, :bulkhead_full}, state}

      true ->
        ref = Process.monitor(pid)

        timer_ref =
          if effective_max_wait == :infinity do
            nil
          else
            Process.send_after(self(), {:waiter_timeout, ref}, effective_max_wait)
          end

        waiters = :queue.in({from, timer_ref, ref}, state.waiters)
        {:noreply, %{state | waiters: waiters, waiter_count: state.waiter_count + 1}}
    end
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      max_concurrent: state.max_concurrent,
      current: state.current,
      available: state.max_concurrent - state.current,
      waiting: state.waiter_count
    }

    {:reply, stats, state}
  end

  def handle_call(:reset, _from, state) do
    # Reject all waiters
    state = reject_all_waiters(state)

    # Demonitor all active monitors
    Enum.each(state.active_monitors, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)

    state = %{state | current: 0, active_monitors: %{}}
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:release_permit, ref}, state) do
    case Map.pop(state.active_monitors, ref) do
      {nil, _} ->
        # Stale release — already cleaned up
        {:noreply, state}

      {_, monitors} ->
        Process.demonitor(ref, [:flush])
        state = %{state | current: state.current - 1, active_monitors: monitors}
        fire_callback(state.on_call_finished, state.name)
        state = grant_next_waiter(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:waiter_timeout, monitor_ref}, state) do
    case remove_waiter_by_monitor(state.waiters, monitor_ref) do
      {:ok, {from, _timer_ref, ^monitor_ref}, new_queue} ->
        Process.demonitor(monitor_ref, [:flush])
        GenServer.reply(from, {:error, :bulkhead_full})
        fire_callback(state.on_call_rejected, state.name)
        {:noreply, %{state | waiters: new_queue, waiter_count: state.waiter_count - 1}}

      :not_found ->
        # Stale timeout — waiter was already granted or removed
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.active_monitors, ref) do
      # Active permit holder died — release the permit
      monitors = Map.delete(state.active_monitors, ref)
      state = %{state | current: state.current - 1, active_monitors: monitors}
      fire_callback(state.on_call_finished, state.name)
      state = grant_next_waiter(state)
      {:noreply, state}
    else
      {:noreply, handle_waiter_down(state, ref)}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internals ---

  defp handle_waiter_down(state, ref) do
    case remove_waiter_by_monitor(state.waiters, ref) do
      {:ok, {_from, timer_ref, ^ref}, new_queue} ->
        if timer_ref, do: Process.cancel_timer(timer_ref)
        # Don't reply — caller is dead
        %{state | waiters: new_queue, waiter_count: state.waiter_count - 1}

      :not_found ->
        # Stale monitor — ignore
        state
    end
  end

  defp grant_next_waiter(state) do
    case :queue.out(state.waiters) do
      {:empty, _} ->
        state

      {{:value, {from, timer_ref, monitor_ref}}, new_queue} ->
        if timer_ref, do: Process.cancel_timer(timer_ref)
        # Reuse the existing monitor ref — move from queue to active_monitors
        state = %{
          state
          | current: state.current + 1,
            active_monitors: Map.put(state.active_monitors, monitor_ref, true),
            waiters: new_queue,
            waiter_count: state.waiter_count - 1
        }

        GenServer.reply(from, {:ok, monitor_ref})
        fire_callback(state.on_call_permitted, state.name)
        state
    end
  end

  defp reject_all_waiters(state) do
    state.waiters
    |> :queue.to_list()
    |> Enum.each(fn {from, timer_ref, monitor_ref} ->
      if timer_ref, do: Process.cancel_timer(timer_ref)
      Process.demonitor(monitor_ref, [:flush])
      GenServer.reply(from, {:error, :bulkhead_full})
      fire_callback(state.on_call_rejected, state.name)
    end)

    %{state | waiters: :queue.new(), waiter_count: 0}
  end

  defp remove_waiter_by_monitor(queue, monitor_ref) do
    list = :queue.to_list(queue)

    case Enum.split_while(list, fn {_from, _timer_ref, ref} -> ref != monitor_ref end) do
      {_before, []} ->
        :not_found

      {before, [waiter | after_list]} ->
        new_queue = :queue.from_list(before ++ after_list)
        {:ok, waiter, new_queue}
    end
  end

  defp fire_callback(nil, _name), do: :ok

  defp fire_callback(callback, name) do
    callback.(name)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- Validation ---

  defp validate_opts!(opts) do
    max_concurrent = Keyword.fetch!(opts, :max_concurrent)
    max_wait = Keyword.get(opts, :max_wait, 0)
    on_call_permitted = Keyword.get(opts, :on_call_permitted)
    on_call_rejected = Keyword.get(opts, :on_call_rejected)
    on_call_finished = Keyword.get(opts, :on_call_finished)

    validate_non_neg_integer!(:max_concurrent, max_concurrent)
    validate_max_wait!(:max_wait, max_wait)

    if on_call_permitted != nil do
      validate_function!(:on_call_permitted, on_call_permitted, 1)
    end

    if on_call_rejected != nil do
      validate_function!(:on_call_rejected, on_call_rejected, 1)
    end

    if on_call_finished != nil do
      validate_function!(:on_call_finished, on_call_finished, 1)
    end
  end

  defp validate_non_neg_integer!(key, value) do
    if not is_integer(value) or value < 0 do
      raise ArgumentError,
            "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp validate_max_wait!(key, value) do
    if value != :infinity and (not is_integer(value) or value < 0) do
      raise ArgumentError,
            "#{key} must be :infinity or a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp validate_function!(key, value, arity) do
    if not is_function(value, arity) do
      raise ArgumentError, "#{key} must be a function of arity #{arity}, got: #{inspect(value)}"
    end
  end
end
