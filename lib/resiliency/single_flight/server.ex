defmodule Resiliency.SingleFlight.Server do
  @moduledoc false

  use GenServer

  defstruct calls: %{}

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:flight, key, fun}, from, state) do
    case Map.fetch(state.calls, key) do
      {:ok, entry} ->
        # Key already in-flight — append caller to waiters
        updated_entry = %{entry | callers: [from | entry.callers]}
        {:noreply, put_in(state.calls[key], updated_entry)}

      :error ->
        # Key not in-flight — spawn task and track it
        task = Task.async(fn -> execute(fun) end)

        entry = %{callers: [from], task_ref: task.ref, task_pid: task.pid}
        {:noreply, put_in(state.calls[key], entry)}
    end
  end

  @impl true
  def handle_cast({:forget, key}, state) do
    case Map.fetch(state.calls, key) do
      {:ok, entry} ->
        # Move existing entry to a ref-only tracking so in-flight waiters
        # still get their result, but new callers with this key start fresh
        forgotten = Map.delete(state.calls, key)
        ref_key = {:ref, entry.task_ref}
        {:noreply, %{state | calls: Map.put(forgotten, ref_key, entry)}}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully — flush the :DOWN message
    Process.demonitor(ref, [:flush])

    case find_entry_by_ref(state.calls, ref) do
      {key, entry} ->
        reply_to_all(entry.callers, result)
        {:noreply, %{state | calls: Map.delete(state.calls, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task crashed
    case find_entry_by_ref(state.calls, ref) do
      {key, entry} ->
        reply_to_all(entry.callers, {:error, reason})
        {:noreply, %{state | calls: Map.delete(state.calls, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp execute(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, {e, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp find_entry_by_ref(calls, ref) do
    Enum.find_value(calls, fn
      {key, %{task_ref: ^ref} = entry} -> {key, entry}
      _ -> nil
    end)
  end

  defp reply_to_all(callers, result) do
    Enum.each(callers, fn from ->
      GenServer.reply(from, result)
    end)
  end
end
