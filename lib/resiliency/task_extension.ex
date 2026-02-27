defmodule Resiliency.TaskExtension do
  @moduledoc """
  Higher-level Task combinators for Elixir.

  Provides `race/1`, `all_settled/1`, `map/3`, and `first_ok/1` — patterns
  commonly found in other languages (JavaScript's `Promise.race`/`Promise.allSettled`,
  Go's `errgroup`, Java's `CompletableFuture`) but missing from Elixir's stdlib.

  All functions are stateless — no GenServer to start, no supervision tree entry.
  Spawned tasks use `spawn_monitor` with a handshake, so task crashes never crash
  the caller.

  ## When to use

    * Querying multiple replicas or services in parallel and using whichever
      responds first (`race/1`) — e.g., hitting a primary and a read-replica
      simultaneously for a latency-sensitive endpoint.
    * Running a batch of independent jobs where partial failure is acceptable
      and you need to know which succeeded (`all_settled/1`) — e.g., sending
      notifications to multiple channels.
    * Processing a collection with bounded parallelism and fail-fast semantics
      (`map/3`) — e.g., uploading files to S3 with at most 10 concurrent
      streams, aborting on the first permission error.
    * Implementing a fallback chain across cache, database, and remote API
      (`first_ok/1`) — each layer is tried sequentially, stopping at the
      first success.

  ## How it works

  **`race/1`** — All functions are spawned concurrently as monitored
  processes. The caller enters a receive loop: the first task to send a
  successful result wins, all remaining tasks are killed via
  `Process.exit(pid, :kill)`, and `{:ok, result}` is returned. If a task
  crashes (`:DOWN` message), it is removed from the active set and the race
  continues with the survivors. If all tasks crash, `{:error, :all_failed}`
  is returned.

  **`all_settled/1`** — Similar to `race`, but the caller waits for every
  task to complete. Results are collected into an Erlang `:array` indexed by
  input position, so the output order always matches the input order
  regardless of completion order. Each slot is `{:ok, value}` or
  `{:error, reason}`. Tasks exceeding the timeout receive
  `{:error, :timeout}`.

  **`map/3`** — Items are processed with a sliding window of at most
  `:max_concurrency` tasks. When a task completes, its result is stored and
  the next pending item is spawned. If any task crashes, all active tasks are
  killed and `{:error, reason}` is returned immediately — no further items
  are started. On success, `{:ok, results}` is returned in input order.

  **`first_ok/1`** — Functions are tried sequentially (not concurrently).
  The first function that returns a non-error value wins. Exceptions, exits,
  throws, and `{:error, _}` tuples are treated as failures, and the next
  function is tried. If all fail, `{:error, :all_failed}` is returned. A
  total `:timeout` can be set — elapsed time is subtracted after each
  attempt.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `race/1` | O(n) spawns + O(n) monitor cleanup where n = number of functions | O(n) — one monitored process per function |
  | `all_settled/1` | O(n) spawns + O(n) result collection | O(n) — `:array` of results + monitored processes |
  | `map/3` | O(n) total spawns where n = number of items, at most c concurrent where c = `max_concurrency` | O(n + c) — `:array` of n results + c active monitored processes |
  | `first_ok/1` | O(n) sequential calls in the worst case | O(1) — only one function executes at a time |

  ## Usage

      # First success wins, cancel the rest
      {:ok, :fast} = Resiliency.TaskExtension.race([
        fn -> Process.sleep(100); :slow end,
        fn -> :fast end
      ])

      # Run all, collect successes and failures
      [{:ok, 1}, {:error, _}] = Resiliency.TaskExtension.all_settled([
        fn -> 1 end,
        fn -> raise "boom" end
      ])

      # Bounded-concurrency map, cancel on first error
      {:ok, [2, 4, 6]} = Resiliency.TaskExtension.map([1, 2, 3], &(&1 * 2), max_concurrency: 2)

      # Sequential fallback chain
      {:ok, "from db"} = Resiliency.TaskExtension.first_ok([
        fn -> {:error, :cache_miss} end,
        fn -> {:ok, "from db"} end
      ])

  ## Return values

  | Function | Success | All fail | Timeout | Empty input |
  |---|---|---|---|---|
  | `race/1,2` | `{:ok, result}` | `{:error, :all_failed}` | `{:error, :timeout}` | `{:error, :empty}` |
  | `all_settled/1,2` | `[{:ok, _}, ...]` | `[{:error, _}, ...]` | `{:error, :timeout}` per task | `[]` |
  | `map/2,3` | `{:ok, results}` | `{:error, reason}` | `{:error, :timeout}` | `{:ok, []}` |
  | `first_ok/1,2` | `{:ok, result}` | `{:error, :all_failed}` | `{:error, :all_failed}` | `{:error, :empty}` |
  """

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

      iex> Resiliency.TaskExtension.race([fn -> :hello end])
      {:ok, :hello}

      iex> Resiliency.TaskExtension.race([
      ...>   fn -> Process.sleep(100); :slow end,
      ...>   fn -> :fast end
      ...> ])
      {:ok, :fast}

      iex> Resiliency.TaskExtension.race([fn -> raise "boom" end])
      {:error, :all_failed}

      iex> Resiliency.TaskExtension.race([])
      {:error, :empty}

  Crashed tasks are skipped — the race continues:

      iex> Resiliency.TaskExtension.race([
      ...>   fn -> raise "primary down" end,
      ...>   fn -> :backup end
      ...> ])
      {:ok, :backup}

  With a timeout:

      Resiliency.TaskExtension.race([
        fn -> fetch_from_slow_service() end,
        fn -> fetch_from_another_service() end
      ], timeout: 5_000)

  """
  @spec race([task_fun()], keyword()) ::
          {:ok, any()} | {:error, :all_failed | :timeout | :empty}
  def race(funs, opts \\ [])

  def race([], _opts), do: {:error, :empty}

  def race(funs, opts) do
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

      iex> Resiliency.TaskExtension.all_settled([fn -> 1 end, fn -> 2 end])
      [{:ok, 1}, {:ok, 2}]

      iex> Resiliency.TaskExtension.all_settled([])
      []

  Mixed successes and failures:

      iex> [{:ok, 1}, {:error, {%RuntimeError{message: "boom"}, _}}, {:ok, 3}] =
      ...>   Resiliency.TaskExtension.all_settled([
      ...>     fn -> 1 end,
      ...>     fn -> raise "boom" end,
      ...>     fn -> 3 end
      ...>   ])

  With a timeout — completed tasks return their results, timed-out tasks
  get `{:error, :timeout}`:

      Resiliency.TaskExtension.all_settled([
        fn -> quick_work() end,
        fn -> slow_work() end
      ], timeout: 1_000)
      # => [{:ok, result}, {:error, :timeout}]

  """
  @spec all_settled([task_fun()], keyword()) :: [{:ok, any()} | {:error, any()}]
  def all_settled(funs, opts \\ [])

  def all_settled([], _opts), do: []

  def all_settled(funs, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    tasks = Enum.map(funs, &spawn_task/1)
    ref_to_index = Map.new(Enum.with_index(tasks), fn {task, i} -> {task.ref, i} end)
    results = :array.new(length(tasks), default: nil)

    results = collect_all(tasks, ref_to_index, results, length(tasks), timeout)

    for i <- 0..(length(tasks) - 1) do
      :array.get(i, results)
    end
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

      iex> Resiliency.TaskExtension.map([1, 2, 3], fn x -> x * 2 end)
      {:ok, [2, 4, 6]}

      iex> Resiliency.TaskExtension.map([], fn x -> x end)
      {:ok, []}

  With bounded concurrency:

      Resiliency.TaskExtension.map(urls, &fetch_url/1, max_concurrency: 10)

  On first failure, remaining work is cancelled:

      {:error, reason} = Resiliency.TaskExtension.map(items, &process/1, max_concurrency: 5)

  """
  @spec map(Enumerable.t(), (any() -> any()), keyword()) :: {:ok, [any()]} | {:error, any()}
  def map(enumerable, fun, opts \\ []) do
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

  @doc """
  Try functions sequentially. Return the first successful result.

  Functions are tried one at a time, in order. A function "succeeds" if it
  returns any value other than `{:error, _}` without raising, exiting, or
  throwing. A function "fails" if it raises, exits, throws, or returns
  `{:error, _}`.

  Successful results are wrapped in `{:ok, result}`. If the function already
  returns `{:ok, value}`, it is passed through unchanged. Functions after the
  first success are never called.

  Returns `{:error, :all_failed}` if all functions fail.
  Returns `{:error, :empty}` for an empty list.

  ## Parameters

  * `funs` -- a list of zero-arity functions to try sequentially.
  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:timeout` -- total timeout across all attempts, in milliseconds or `:infinity`. Defaults to `:infinity`.

  ## Returns

  `{:ok, result}` from the first function that succeeds, `{:error, :all_failed}` if all functions fail or the timeout expires, or `{:error, :empty}` if the input list is empty.

  ## Examples

      iex> Resiliency.TaskExtension.first_ok([fn -> :hello end])
      {:ok, :hello}

      iex> Resiliency.TaskExtension.first_ok([
      ...>   fn -> {:error, :miss} end,
      ...>   fn -> {:ok, "found"} end
      ...> ])
      {:ok, "found"}

      iex> Resiliency.TaskExtension.first_ok([fn -> raise "boom" end])
      {:error, :all_failed}

      iex> Resiliency.TaskExtension.first_ok([])
      {:error, :empty}

  Typical usage — cache / DB / API fallback:

      Resiliency.TaskExtension.first_ok([
        fn -> fetch_from_cache(key) end,
        fn -> fetch_from_db(key) end,
        fn -> fetch_from_api(key) end
      ])

  """
  @spec first_ok([task_fun()], keyword()) :: {:ok, any()} | {:error, :all_failed | :empty}
  def first_ok(funs, opts \\ [])

  def first_ok([], _opts), do: {:error, :empty}

  def first_ok(funs, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    do_first_ok(funs, timeout)
  end

  defp do_first_ok([], _timeout), do: {:error, :all_failed}

  defp do_first_ok([fun | rest], timeout) do
    start = System.monotonic_time(:millisecond)

    case try_fun(fun) do
      {:ok, _} = ok_result ->
        ok_result

      :failed ->
        new_timeout = subtract_elapsed(timeout, start)

        if timed_out?(new_timeout),
          do: {:error, :all_failed},
          else: do_first_ok(rest, new_timeout)
    end
  end

  defp try_fun(fun) do
    case fun.() do
      {:error, _} -> :failed
      {:ok, value} -> {:ok, value}
      other -> {:ok, other}
    end
  rescue
    _ -> :failed
  catch
    :exit, _ -> :failed
    :throw, _ -> :failed
  end

  defp subtract_elapsed(:infinity, _start), do: :infinity

  defp subtract_elapsed(timeout, start) do
    elapsed = System.monotonic_time(:millisecond) - start
    remaining_timeout(timeout, elapsed)
  end

  defp timed_out?(:infinity), do: false
  defp timed_out?(t) when t <= 0, do: true
  defp timed_out?(_t), do: false

  # Helpers

  defp spawn_task(fun) do
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

  defp shutdown_tasks(tasks) do
    Enum.each(tasks, fn task ->
      Process.demonitor(task.ref, [:flush])
      Process.exit(task.pid, :kill)
    end)
  end

  defp remaining_timeout(:infinity, _elapsed), do: :infinity
  defp remaining_timeout(timeout, elapsed), do: max(timeout - elapsed, 0)

  defp timeout_value(:infinity), do: :infinity
  defp timeout_value(ms) when is_integer(ms) and ms <= 0, do: 0
  defp timeout_value(ms) when is_integer(ms), do: ms
end
