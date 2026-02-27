defmodule Resiliency.CircuitBreaker.Server do
  @moduledoc false
  use GenServer

  alias Resiliency.CircuitBreaker.SlidingWindow

  defstruct [
    :name,
    :window,
    :failure_rate_threshold,
    :slow_call_threshold,
    :slow_call_rate_threshold,
    :open_timeout,
    :permitted_calls_in_half_open,
    :minimum_calls,
    :should_record,
    :on_state_change,
    state: :closed,
    half_open_permits_issued: 0,
    half_open_window: nil,
    open_timer: nil,
    forced: false,
    permit_monitors: %{}
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
    name = Keyword.fetch!(opts, :name)
    window_size = Keyword.get(opts, :window_size, 100)
    permitted = Keyword.get(opts, :permitted_calls_in_half_open, 1)

    state = %__MODULE__{
      name: name,
      window: SlidingWindow.new(window_size),
      failure_rate_threshold: Keyword.get(opts, :failure_rate_threshold, 0.5),
      slow_call_threshold: Keyword.get(opts, :slow_call_threshold, :infinity),
      slow_call_rate_threshold: Keyword.get(opts, :slow_call_rate_threshold, 1.0),
      open_timeout: Keyword.get(opts, :open_timeout, 60_000),
      permitted_calls_in_half_open: permitted,
      minimum_calls: Keyword.get(opts, :minimum_calls, 10),
      should_record: Keyword.get(opts, :should_record, &default_should_record/1),
      on_state_change: Keyword.get(opts, :on_state_change, nil)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:check_permission, _from, %{state: :closed} = state) do
    {:reply, {:ok, state.should_record}, state}
  end

  def handle_call(:check_permission, _from, %{state: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call(:check_permission, _from, %{state: :half_open} = state) do
    if state.half_open_permits_issued < state.permitted_calls_in_half_open do
      state = %{state | half_open_permits_issued: state.half_open_permits_issued + 1}
      {:reply, {:ok, state.should_record}, state}
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call(:check_permission_monitored, {pid, _tag}, %{state: :closed} = state) do
    ref = Process.monitor(pid)
    monitors = Map.put(state.permit_monitors, ref, :closed)
    {:reply, {:ok, state.should_record, ref}, %{state | permit_monitors: monitors}}
  end

  def handle_call(:check_permission_monitored, _from, %{state: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call(:check_permission_monitored, {pid, _tag}, %{state: :half_open} = state) do
    if state.half_open_permits_issued < state.permitted_calls_in_half_open do
      ref = Process.monitor(pid)
      monitors = Map.put(state.permit_monitors, ref, :half_open)

      state = %{
        state
        | half_open_permits_issued: state.half_open_permits_issued + 1,
          permit_monitors: monitors
      }

      {:reply, {:ok, state.should_record, ref}, state}
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  def handle_call(:get_stats, _from, state) do
    window =
      case state.state do
        :half_open when state.half_open_window != nil -> state.half_open_window
        _ -> state.window
      end

    stats = Map.put(SlidingWindow.stats(window), :state, state.state)

    {:reply, stats, state}
  end

  def handle_call(:reset, _from, state) do
    old_state = state.state
    state = cancel_timer(state)
    state = demonitor_all_permits(state)

    state = %{
      state
      | state: :closed,
        window: SlidingWindow.reset(state.window),
        half_open_permits_issued: 0,
        half_open_window: nil,
        forced: false
    }

    fire_state_change(state, old_state, :closed)
    {:reply, :ok, state}
  end

  def handle_call(:force_open, _from, state) do
    old_state = state.state
    state = cancel_timer(state)
    state = demonitor_all_permits(state)

    state = %{
      state
      | state: :open,
        half_open_permits_issued: 0,
        half_open_window: nil,
        forced: true
    }

    fire_state_change(state, old_state, :open)
    {:reply, :ok, state}
  end

  def handle_call(:force_close, _from, state) do
    old_state = state.state
    state = cancel_timer(state)
    state = demonitor_all_permits(state)

    state = %{
      state
      | state: :closed,
        window: SlidingWindow.reset(state.window),
        half_open_permits_issued: 0,
        half_open_window: nil,
        forced: false
    }

    fire_state_change(state, old_state, :closed)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:release_permit, %{state: :half_open} = state) do
    # An ignored result in half_open — release the permit so more probes can flow.
    state = %{state | half_open_permits_issued: max(state.half_open_permits_issued - 1, 0)}
    {:noreply, state}
  end

  def handle_cast(:release_permit, state) do
    # Not in half_open — nothing to release.
    {:noreply, state}
  end

  def handle_cast({:demonitor_permit, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | permit_monitors: Map.delete(state.permit_monitors, ref)}}
  end

  def handle_cast({:record, _outcome, _duration_ms}, %{state: :open} = state) do
    # Stale recording from before the circuit tripped — ignore.
    {:noreply, state}
  end

  def handle_cast({:record, outcome, duration_ms}, %{state: :closed} = state) do
    slow? = slow?(duration_ms, state.slow_call_threshold)
    window = SlidingWindow.record(state.window, outcome, slow?)
    state = %{state | window: window}
    state = maybe_trip(state)
    {:noreply, state}
  end

  def handle_cast({:record, outcome, duration_ms}, %{state: :half_open} = state) do
    slow? = slow?(duration_ms, state.slow_call_threshold)
    ho_window = SlidingWindow.record(state.half_open_window, outcome, slow?)
    state = %{state | half_open_window: ho_window}
    state = maybe_evaluate_half_open(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:open_timeout, %{state: :open, forced: false} = state) do
    state = transition(state, :half_open)
    {:noreply, state}
  end

  def handle_info(:open_timeout, state) do
    # Stale timer — ignore.
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {grant_state, monitors} = Map.pop(state.permit_monitors, ref)
    state = %{state | permit_monitors: monitors}

    case {grant_state, state.state} do
      {nil, _} ->
        # Already cleaned up (record fired before DOWN arrived).
        {:noreply, state}

      {:half_open, :half_open} ->
        slow? = slow?(0, state.slow_call_threshold)
        ho_window = SlidingWindow.record(state.half_open_window, :failure, slow?)
        state = %{state | half_open_window: ho_window}
        state = maybe_evaluate_half_open(state)
        {:noreply, state}

      {:closed, :closed} ->
        slow? = slow?(0, state.slow_call_threshold)
        window = SlidingWindow.record(state.window, :failure, slow?)
        state = %{state | window: window}
        state = maybe_trip(state)
        {:noreply, state}

      _ ->
        # Stale monitor from a previous state — just clean up.
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internals ---

  defp default_should_record({:ok, _}), do: :success
  defp default_should_record({:error, _}), do: :failure
  defp default_should_record(_), do: :success

  defp slow?(duration_ms, :infinity), do: duration_ms == :slow
  defp slow?(:slow, _threshold), do: true
  defp slow?(duration_ms, threshold), do: duration_ms >= threshold

  defp maybe_trip(%{state: :closed} = state) do
    window = state.window

    if window.total >= state.minimum_calls do
      failure_rate = SlidingWindow.failure_rate(window)
      slow_rate = SlidingWindow.slow_call_rate(window)

      if failure_rate >= state.failure_rate_threshold or
           slow_rate >= state.slow_call_rate_threshold do
        transition(state, :open)
      else
        state
      end
    else
      state
    end
  end

  defp maybe_evaluate_half_open(%{state: :half_open} = state) do
    ho_window = state.half_open_window

    if ho_window.total >= state.permitted_calls_in_half_open do
      failure_rate = SlidingWindow.failure_rate(ho_window)
      slow_rate = SlidingWindow.slow_call_rate(ho_window)

      if failure_rate >= state.failure_rate_threshold or
           slow_rate >= state.slow_call_rate_threshold do
        transition(state, :open)
      else
        transition(state, :closed)
      end
    else
      state
    end
  end

  defp transition(state, new_state) do
    old_state = state.state
    state = cancel_timer(state)
    state = demonitor_all_permits(state)

    state =
      case new_state do
        :open ->
          timer = Process.send_after(self(), :open_timeout, state.open_timeout)

          %{
            state
            | state: :open,
              open_timer: timer,
              half_open_permits_issued: 0,
              half_open_window: nil,
              forced: false
          }

        :half_open ->
          %{
            state
            | state: :half_open,
              half_open_permits_issued: 0,
              half_open_window: SlidingWindow.new(state.permitted_calls_in_half_open),
              forced: false
          }

        :closed ->
          %{
            state
            | state: :closed,
              window: SlidingWindow.reset(state.window),
              half_open_permits_issued: 0,
              half_open_window: nil,
              forced: false
          }
      end

    fire_state_change(state, old_state, new_state)
    state
  end

  defp demonitor_all_permits(%{permit_monitors: monitors} = state) when monitors == %{} do
    state
  end

  defp demonitor_all_permits(%{permit_monitors: monitors} = state) do
    Enum.each(monitors, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    %{state | permit_monitors: %{}}
  end

  defp cancel_timer(%{open_timer: nil} = state), do: state

  defp cancel_timer(%{open_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | open_timer: nil}
  end

  defp fire_state_change(_state, same, same), do: :ok

  defp fire_state_change(%{on_state_change: nil}, _old, _new), do: :ok

  defp fire_state_change(state, old_state, new_state) do
    state.on_state_change.(state.name, old_state, new_state)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- Validation ---

  defp validate_opts!(opts) do
    window_size = Keyword.get(opts, :window_size, 100)
    failure_rate_threshold = Keyword.get(opts, :failure_rate_threshold, 0.5)
    slow_call_threshold = Keyword.get(opts, :slow_call_threshold, :infinity)
    slow_call_rate_threshold = Keyword.get(opts, :slow_call_rate_threshold, 1.0)
    open_timeout = Keyword.get(opts, :open_timeout, 60_000)
    permitted = Keyword.get(opts, :permitted_calls_in_half_open, 1)
    minimum_calls = Keyword.get(opts, :minimum_calls, 10)
    should_record = Keyword.get(opts, :should_record)
    on_state_change = Keyword.get(opts, :on_state_change)

    validate_pos_integer!(:window_size, window_size)
    validate_pos_integer!(:permitted_calls_in_half_open, permitted)
    validate_pos_integer!(:minimum_calls, minimum_calls)
    validate_pos_integer!(:open_timeout, open_timeout)
    validate_rate!(:failure_rate_threshold, failure_rate_threshold)
    validate_rate!(:slow_call_rate_threshold, slow_call_rate_threshold)
    validate_slow_call_threshold!(slow_call_threshold)

    if should_record != nil do
      validate_function!(:should_record, should_record, 1)
    end

    if on_state_change != nil do
      validate_function!(:on_state_change, on_state_change, 3)
    end
  end

  defp validate_pos_integer!(key, value) do
    if not is_integer(value) or value < 1 do
      raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp validate_rate!(key, value) do
    if not is_number(value) or value < 0.0 or value > 1.0 do
      raise ArgumentError, "#{key} must be a number between 0.0 and 1.0, got: #{inspect(value)}"
    end
  end

  defp validate_slow_call_threshold!(value) do
    if value != :infinity and (not is_integer(value) or value < 0) do
      raise ArgumentError,
            "slow_call_threshold must be :infinity or a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp validate_function!(key, value, arity) do
    if not is_function(value, arity) do
      raise ArgumentError, "#{key} must be a function of arity #{arity}, got: #{inspect(value)}"
    end
  end
end
