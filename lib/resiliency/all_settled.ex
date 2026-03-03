defmodule Resiliency.AllSettled do
  @moduledoc """
  Run all functions concurrently and collect every result, regardless of failures.

  ## When to use

    * Running a batch of independent jobs where partial failure is acceptable
      and you need to know which succeeded — e.g., sending notifications to
      multiple channels.
    * Executing health checks or non-critical side effects in parallel and
      inspecting each outcome individually.

  ## How it works

  All functions are spawned concurrently as monitored processes. The caller
  waits for every task to complete. Results are collected into an Erlang
  `:array` indexed by input position, so the output order always matches
  the input order regardless of completion order. Each slot is
  `{:ok, value}` or `{:error, reason}`. Tasks exceeding the timeout receive
  `{:error, :timeout}`.

  ## Algorithm Complexity

  | Time | Space |
  |---|---|
  | O(n) spawns + O(n) result collection | O(n) — `:array` of results + monitored processes |

  ## Examples

      iex> Resiliency.AllSettled.run([fn -> 1 end, fn -> 2 end])
      [{:ok, 1}, {:ok, 2}]

      iex> Resiliency.AllSettled.run([])
      []

  Mixed successes and failures:

      iex> [{:ok, 1}, {:error, {%RuntimeError{message: "boom"}, _}}, {:ok, 3}] =
      ...>   Resiliency.AllSettled.run([
      ...>     fn -> 1 end,
      ...>     fn -> raise "boom" end,
      ...>     fn -> 3 end
      ...>   ])

  With a timeout — completed tasks return their results, timed-out tasks
  get `{:error, :timeout}`:

      Resiliency.AllSettled.run([
        fn -> quick_work() end,
        fn -> slow_work() end
      ], timeout: 1_000)
      # => [{:ok, result}, {:error, :timeout}]

  ## Telemetry

  All events are emitted in the caller's process via `:telemetry.span/3`. See
  `Resiliency.Telemetry` for the complete event catalogue.

  ### `[:resiliency, :all_settled, :run, :start]`

  Emitted before tasks are spawned.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `system_time` | `integer` | `System.system_time()` at emission time |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `count` | `integer` | Number of functions submitted |

  ### `[:resiliency, :all_settled, :run, :stop]`

  Emitted after all tasks complete (or timeout).

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `duration` | `integer` | Elapsed native time units (`System.monotonic_time/0` delta) |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `count` | `integer` | Total number of tasks |
  | `ok_count` | `integer` | Number of tasks that returned `{:ok, _}` |
  | `error_count` | `integer` | Number of tasks that returned `{:error, _}` |

  ### `[:resiliency, :all_settled, :run, :exception]`

  Emitted if `run/2` raises or exits unexpectedly.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `duration` | `integer` | Elapsed native time units |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `count` | `integer` | Number of functions submitted |
  | `kind` | `atom` | Exception kind (`:error`, `:exit`, or `:throw`) |
  | `reason` | `term` | The exception or exit reason |
  | `stacktrace` | `list` | Stack at the point of the exception |

  """

  import Resiliency.TaskHelper,
    only: [spawn_task: 1, shutdown_tasks: 1, remaining_timeout: 2, timeout_value: 1]

  @type task_fun :: (-> any())

  @doc """
  Run all functions concurrently. Wait for all to complete and return results in input order.

  Unlike `Task.await_many/2`, this never crashes the caller. Each result is
  `{:ok, value}` or `{:error, reason}`. Results are always in the same order
  as the input list, regardless of which tasks finish first. Tasks that exceed
  the timeout get `{:error, :timeout}`.

  Returns `[]` for an empty list.

  ## Parameters

  * `funs` -- a list of zero-arity functions to execute concurrently.
  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:timeout` -- milliseconds or `:infinity`. Defaults to `:infinity`.

  ## Returns

  A list of `{:ok, value}` or `{:error, reason}` tuples in the same order as the input list. Tasks that exceed the timeout produce `{:error, :timeout}`. An empty input list returns `[]`.

  ## Examples

      iex> Resiliency.AllSettled.run([fn -> 1 end, fn -> 2 end])
      [{:ok, 1}, {:ok, 2}]

      iex> Resiliency.AllSettled.run([])
      []

  """
  @spec run([task_fun()], keyword()) :: [{:ok, any()} | {:error, any()}]
  def run(funs, opts \\ [])

  def run([], _opts), do: []

  def run(funs, opts) do
    count = length(funs)
    meta = %{count: count}

    :telemetry.span([:resiliency, :all_settled, :run], meta, fn ->
      timeout = Keyword.get(opts, :timeout, :infinity)
      tasks = Enum.map(funs, &spawn_task/1)
      ref_to_index = Map.new(Enum.with_index(tasks), fn {task, i} -> {task.ref, i} end)
      results = :array.new(length(tasks), default: nil)
      results = collect_all(tasks, ref_to_index, results, length(tasks), timeout)

      result_list =
        for i <- 0..(length(tasks) - 1) do
          :array.get(i, results)
        end

      ok_count = Enum.count(result_list, &match?({:ok, _}, &1))
      error_count = count - ok_count

      {result_list, %{count: count, ok_count: ok_count, error_count: error_count}}
    end)
  end

  defp collect_all(_tasks, _ref_to_index, results, 0, _timeout), do: results

  defp collect_all(tasks, ref_to_index, results, remaining, timeout) do
    start = System.monotonic_time(:millisecond)

    receive do
      {ref, result} when is_map_key(ref_to_index, ref) ->
        Process.demonitor(ref, [:flush])
        index = Map.fetch!(ref_to_index, ref)
        results = :array.set(index, {:ok, result}, results)
        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout(timeout, elapsed)
        collect_all(tasks, ref_to_index, results, remaining - 1, new_timeout)

      {:DOWN, ref, _, _, reason} when is_map_key(ref_to_index, ref) ->
        index = Map.fetch!(ref_to_index, ref)
        results = :array.set(index, {:error, reason}, results)
        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout(timeout, elapsed)
        collect_all(tasks, ref_to_index, results, remaining - 1, new_timeout)
    after
      timeout_value(timeout) ->
        results =
          Enum.reduce(ref_to_index, results, fn {_ref, index}, acc ->
            case :array.get(index, acc) do
              nil -> :array.set(index, {:error, :timeout}, acc)
              _ -> acc
            end
          end)

        shutdown_tasks(tasks)
        results
    end
  end
end
