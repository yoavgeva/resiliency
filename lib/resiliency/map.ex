defmodule Resiliency.Map do
  @moduledoc """
  Map over an enumerable with bounded concurrency, cancelling on first error.

  ## When to use

    * Processing a collection with bounded parallelism and fail-fast semantics
      — e.g., uploading files to S3 with at most 10 concurrent streams,
      aborting on the first permission error.
    * Fetching data from multiple URLs in parallel with a concurrency cap.

  ## How it works

  Items are processed with a sliding window of at most `:max_concurrency`
  tasks. When a task completes, its result is stored and the next pending
  item is spawned. If any task crashes, all active tasks are killed and
  `{:error, reason}` is returned immediately — no further items are started.
  On success, `{:ok, results}` is returned in input order.

  ## Algorithm Complexity

  | Time | Space |
  |---|---|
  | O(n) total spawns where n = number of items, at most c concurrent where c = `max_concurrency` | O(n + c) — `:array` of n results + c active monitored processes |

  ## Examples

      iex> Resiliency.Map.run([1, 2, 3], fn x -> x * 2 end)
      {:ok, [2, 4, 6]}

      iex> Resiliency.Map.run([], fn x -> x end)
      {:ok, []}

  With bounded concurrency:

      Resiliency.Map.run(urls, &fetch_url/1, max_concurrency: 10)

  On first failure, remaining work is cancelled:

      {:error, reason} = Resiliency.Map.run(items, &process/1, max_concurrency: 5)

  """

  import Resiliency.TaskHelper,
    only: [spawn_task: 1, shutdown_tasks: 1, remaining_timeout: 2, timeout_value: 1]

  @doc """
  Map over an enumerable with bounded concurrency, cancelling on first error.

  Like `Task.async_stream/3` but returns `{:ok, results}` or `{:error, reason}`
  instead of a stream, and **cancels all remaining work on the first failure**.
  At most `max_concurrency` tasks run at once. Results are always in input order.

  Returns `{:ok, []}` for an empty enumerable.

  ## Parameters

  * `enumerable` -- any `Enumerable` of items to map over.
  * `fun` -- a one-arity function to apply to each item.
  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:max_concurrency` -- max tasks running at once. Defaults to `System.schedulers_online()`.
    * `:timeout` -- milliseconds or `:infinity`. Defaults to `:infinity`.

  ## Returns

  `{:ok, results}` where `results` is a list of return values in input order, or `{:error, reason}` on the first task failure or timeout.

  ## Examples

      iex> Resiliency.Map.run([1, 2, 3], fn x -> x * 2 end)
      {:ok, [2, 4, 6]}

      iex> Resiliency.Map.run([], fn x -> x end)
      {:ok, []}

  """
  @spec run(Enumerable.t(), (any() -> any()), keyword()) :: {:ok, [any()]} | {:error, any()}
  def run(enumerable, fun, opts \\ []) do
    items = Enum.to_list(enumerable)

    case items do
      [] ->
        {:ok, []}

      _ ->
        max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
        timeout = Keyword.get(opts, :timeout, :infinity)
        do_map(items, fun, max_concurrency, timeout)
    end
  end

  defp do_map(items, fun, max_concurrency, timeout) do
    indexed = Enum.with_index(items)
    results = :array.new(length(items), default: nil)

    {initial_batch, rest} = Enum.split(indexed, max_concurrency)

    active =
      Map.new(initial_batch, fn {item, index} ->
        task = spawn_task(fn -> fun.(item) end)
        {task.ref, {task, index}}
      end)

    collect_map(active, rest, results, fun, length(items), timeout)
  end

  defp collect_map(active, _pending, results, _fun, total, _timeout)
       when map_size(active) == 0 do
    collected =
      for i <- 0..(total - 1) do
        :array.get(i, results)
      end

    {:ok, collected}
  end

  defp collect_map(active, pending, results, fun, total, timeout) do
    start = System.monotonic_time(:millisecond)

    receive do
      {ref, result} when is_map_key(active, ref) ->
        Process.demonitor(ref, [:flush])
        {_task, index} = Map.fetch!(active, ref)
        results = :array.set(index, result, results)
        active = Map.delete(active, ref)

        {active, pending} =
          case pending do
            [{item, idx} | rest] ->
              task = spawn_task(fn -> fun.(item) end)
              {Map.put(active, task.ref, {task, idx}), rest}

            [] ->
              {active, []}
          end

        elapsed = System.monotonic_time(:millisecond) - start
        new_timeout = remaining_timeout(timeout, elapsed)
        collect_map(active, pending, results, fun, total, new_timeout)

      {:DOWN, ref, _, _, reason} when is_map_key(active, ref) ->
        active_tasks = for {_ref, {task, _idx}} <- Map.delete(active, ref), do: task
        shutdown_tasks(active_tasks)
        {:error, reason}
    after
      timeout_value(timeout) ->
        active_tasks = for {_ref, {task, _idx}} <- active, do: task
        shutdown_tasks(active_tasks)
        {:error, :timeout}
    end
  end
end
