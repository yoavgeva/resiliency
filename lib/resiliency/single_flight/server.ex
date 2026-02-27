defmodule Resiliency.SingleFlight.Server do
  @moduledoc false

  use GenServer

  defstruct calls: %{}, ref_to_key: %{}, task_supervisor: nil

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, %__MODULE__{task_supervisor: task_supervisor}}
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
        task = Task.Supervisor.async_nolink(state.task_supervisor, fn -> execute(fun) end)

        entry = %{callers: [from], task_ref: task.ref, task_pid: task.pid}

        state = %{
          state
          | calls: Map.put(state.calls, key, entry),
            ref_to_key: Map.put(state.ref_to_key, task.ref, key)
        }

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:forget, key}, state) do
    case Map.fetch(state.calls, key) do
      {:ok, entry} ->
        # Move existing entry to a ref-only tracking so in-flight waiters
        # still get their result, but new callers with this key start fresh
        ref_key = {:ref, entry.task_ref}

        state = %{
          state
          | calls: state.calls |> Map.delete(key) |> Map.put(ref_key, entry),
            ref_to_key: Map.put(state.ref_to_key, entry.task_ref, ref_key)
        }

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully — flush the :DOWN message
    Process.demonitor(ref, [:flush])

    case Map.fetch(state.ref_to_key, ref) do
      {:ok, key} ->
        entry = Map.fetch!(state.calls, key)
        reply_to_all(entry.callers, result)

        state = %{
          state
          | calls: Map.delete(state.calls, key),
            ref_to_key: Map.delete(state.ref_to_key, ref)
        }

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task crashed
    case Map.fetch(state.ref_to_key, ref) do
      {:ok, key} ->
        entry = Map.fetch!(state.calls, key)
        reply_to_all(entry.callers, {:error, reason})

        state = %{
          state
          | calls: Map.delete(state.calls, key),
            ref_to_key: Map.delete(state.ref_to_key, ref)
        }

        {:noreply, state}

      :error ->
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

  defp reply_to_all(callers, result) do
    Enum.each(callers, fn from ->
      GenServer.reply(from, result)
    end)
  end
end
