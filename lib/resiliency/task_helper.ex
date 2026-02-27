defmodule Resiliency.TaskHelper do
  @moduledoc false

  @doc false
  def spawn_task(fun) do
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

  @doc false
  def shutdown_tasks(tasks) do
    Enum.each(tasks, fn task ->
      Process.demonitor(task.ref, [:flush])
      Process.exit(task.pid, :kill)
    end)
  end

  @doc false
  def remaining_timeout(:infinity, _elapsed), do: :infinity
  def remaining_timeout(timeout, elapsed), do: max(timeout - elapsed, 0)

  @doc false
  def timeout_value(:infinity), do: :infinity
  def timeout_value(ms) when is_integer(ms) and ms <= 0, do: 0
  def timeout_value(ms) when is_integer(ms), do: ms
end
