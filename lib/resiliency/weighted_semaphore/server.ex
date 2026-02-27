defmodule Resiliency.WeightedSemaphore.Server do
  @moduledoc false
  use GenServer

  defstruct [:max, current: 0, waiters: :queue.new(), tasks: %{}]

  # --- Client ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    max = Keyword.fetch!(opts, :max)

    if max < 1, do: raise(ArgumentError, "max must be a positive integer, got: #{inspect(max)}")

    GenServer.start_link(__MODULE__, max, name: name)
  end

  # --- Server callbacks ---

  @impl true
  def init(max) do
    {:ok, %__MODULE__{max: max}}
  end

  @impl true
  def handle_call({:acquire, weight, fun}, from, state) do
    cond do
      weight < 1 ->
        {:reply, {:error, :invalid_weight}, state}

      weight > state.max ->
        {:reply, {:error, :weight_exceeds_max}, state}

      state.current + weight <= state.max and :queue.is_empty(state.waiters) ->
        state = spawn_task(from, weight, fun, state)
        {:noreply, state}

      true ->
        waiters = :queue.in({from, weight, fun}, state.waiters)
        {:noreply, %{state | waiters: waiters}}
    end
  end

  @impl true
  def handle_call({:try_acquire, weight, fun}, from, state) do
    cond do
      weight < 1 ->
        {:reply, {:error, :invalid_weight}, state}

      weight > state.max ->
        {:reply, {:error, :weight_exceeds_max}, state}

      state.current + weight <= state.max and :queue.is_empty(state.waiters) ->
        state = spawn_task(from, weight, fun, state)
        {:noreply, state}

      true ->
        {:reply, :rejected, state}
    end
  end

  # Task completed (normal or crash) — all results come via :DOWN
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {{from, weight}, tasks} ->
        reply =
          case reason do
            {:normal, result} -> {:ok, result}
            other -> {:error, other}
          end

        GenServer.reply(from, reply)
        state = %{state | current: state.current - weight, tasks: tasks}
        state = notify_waiters(state)
        {:noreply, state}

      {nil, _tasks} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internals ---

  defp spawn_task(from, weight, fun, state) do
    {_pid, ref} = spawn_monitor(fn -> exit({:normal, fun.()}) end)

    %{
      state
      | current: state.current + weight,
        tasks: Map.put(state.tasks, ref, {from, weight})
    }
  end

  defp notify_waiters(state) do
    case :queue.peek(state.waiters) do
      {:value, {{pid, _tag}, _weight, _fun}} when is_pid(pid) ->
        if Process.alive?(pid) do
          dispatch_front_waiter(state)
        else
          # Caller timed out or died — skip this zombie waiter
          {_popped, rest} = :queue.out(state.waiters)
          notify_waiters(%{state | waiters: rest})
        end

      {:value, _} ->
        dispatch_front_waiter(state)

      :empty ->
        state
    end
  end

  defp dispatch_front_waiter(state) do
    case :queue.peek(state.waiters) do
      {:value, {_from, weight, _fun}} when state.current + weight <= state.max ->
        {{:value, {from, weight, fun}}, rest} = :queue.out(state.waiters)
        state = %{state | waiters: rest}
        state = spawn_task(from, weight, fun, state)
        notify_waiters(state)

      # Next waiter doesn't fit — stop (FIFO fairness)
      _ ->
        state
    end
  end
end
