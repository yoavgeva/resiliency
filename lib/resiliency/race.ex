defmodule Resiliency.Race do
  @moduledoc """
  Run all functions concurrently and return the first successful result.

  ## When to use

    * Querying multiple replicas or services in parallel and using whichever
      responds first — e.g., hitting a primary and a read-replica
      simultaneously for a latency-sensitive endpoint.
    * Sending the same request to multiple regions or providers and taking
      the fastest response.

  ## How it works

  All functions are spawned concurrently as monitored processes. The caller
  enters a receive loop: the first task to send a successful result wins,
  all remaining tasks are killed via `Process.exit(pid, :kill)`, and
  `{:ok, result}` is returned. If a task crashes (`:DOWN` message), it is
  removed from the active set and the race continues with the survivors.
  If all tasks crash, `{:error, :all_failed}` is returned.

  ## Algorithm Complexity

  | Time | Space |
  |---|---|
  | O(n) spawns + O(n) monitor cleanup where n = number of functions | O(n) — one monitored process per function |

  ## Examples

      iex> Resiliency.Race.run([fn -> :hello end])
      {:ok, :hello}

      iex> Resiliency.Race.run([
      ...>   fn -> Process.sleep(100); :slow end,
      ...>   fn -> :fast end
      ...> ])
      {:ok, :fast}

      iex> Resiliency.Race.run([fn -> raise "boom" end])
      {:error, :all_failed}

      iex> Resiliency.Race.run([])
      {:error, :empty}

  Crashed tasks are skipped — the race continues:

      iex> Resiliency.Race.run([
      ...>   fn -> raise "primary down" end,
      ...>   fn -> :backup end
      ...> ])
      {:ok, :backup}

  With a timeout:

      Resiliency.Race.run([
        fn -> fetch_from_slow_service() end,
        fn -> fetch_from_another_service() end
      ], timeout: 5_000)

  """

  import Resiliency.TaskHelper,
    only: [spawn_task: 1, shutdown_tasks: 1, remaining_timeout: 2, timeout_value: 1]

  @type task_fun :: (-> any())

  @doc """
  Run all functions concurrently. Return the first successful result and cancel the rest.

  Spawns all functions as concurrent tasks. The first task to complete
  successfully wins — its result is returned and all remaining tasks are
  shut down. If a task crashes (raise, exit, or throw), it is skipped and
  the race continues with the remaining tasks.

  Returns `{:ok, result}` from the first function that completes successfully.
  If all functions fail, returns `{:error, :all_failed}`.
  If no function succeeds within the timeout, returns `{:error, :timeout}`.
  An empty list returns `{:error, :empty}`.

  ## Parameters

  * `funs` -- a list of zero-arity functions to race concurrently.
  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:timeout` -- milliseconds or `:infinity`. Defaults to `:infinity`.

  ## Returns

  `{:ok, result}` from the first function that completes successfully, `{:error, :all_failed}` if all functions fail, `{:error, :timeout}` if no function succeeds within the timeout, or `{:error, :empty}` if the input list is empty.

  ## Examples

      iex> Resiliency.Race.run([fn -> :hello end])
      {:ok, :hello}

      iex> Resiliency.Race.run([
      ...>   fn -> Process.sleep(100); :slow end,
      ...>   fn -> :fast end
      ...> ])
      {:ok, :fast}

      iex> Resiliency.Race.run([fn -> raise "boom" end])
      {:error, :all_failed}

      iex> Resiliency.Race.run([])
      {:error, :empty}

  """
  @spec run([task_fun()], keyword()) ::
          {:ok, any()} | {:error, :all_failed | :timeout | :empty}
  def run(funs, opts \\ [])

  def run([], _opts), do: {:error, :empty}

  def run(funs, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    tasks = Enum.map(funs, &spawn_task/1)
    task_set = Map.new(tasks, fn task -> {task.ref, task} end)
    do_race(task_set, map_size(task_set), timeout)
  end

  defp do_race(_task_set, 0, _timeout), do: {:error, :all_failed}

  defp do_race(task_set, remaining, timeout) do
    start = System.monotonic_time(:millisecond)

    receive do
      {ref, result} when is_map_key(task_set, ref) ->
        Process.demonitor(ref, [:flush])
        shutdown_tasks(Map.values(Map.delete(task_set, ref)))
        {:ok, result}

      {:DOWN, ref, _, _, _reason} when is_map_key(task_set, ref) ->
        new_task_set = Map.delete(task_set, ref)
        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout(timeout, elapsed)
        do_race(new_task_set, remaining - 1, new_timeout)
    after
      timeout_value(timeout) ->
        shutdown_tasks(Map.values(task_set))
        {:error, :timeout}
    end
  end
end
