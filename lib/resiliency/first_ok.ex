defmodule Resiliency.FirstOk do
  @moduledoc """
  Try functions sequentially and return the first successful result.

  ## When to use

    * Implementing a fallback chain across cache, database, and remote API
      — each layer is tried sequentially, stopping at the first success.
    * Trying multiple parsing strategies or data sources in priority order.

  ## How it works

  Functions are tried sequentially (not concurrently). The first function
  that returns a non-error value wins. Exceptions, exits, throws, and
  `{:error, _}` tuples are treated as failures, and the next function is
  tried. If all fail, `{:error, :all_failed}` is returned. A total
  `:timeout` can be set — elapsed time is subtracted after each attempt.

  ## Algorithm Complexity

  | Time | Space |
  |---|---|
  | O(n) sequential calls in the worst case | O(1) — only one function executes at a time |

  ## Examples

      iex> Resiliency.FirstOk.run([fn -> :hello end])
      {:ok, :hello}

      iex> Resiliency.FirstOk.run([
      ...>   fn -> {:error, :miss} end,
      ...>   fn -> {:ok, "found"} end
      ...> ])
      {:ok, "found"}

      iex> Resiliency.FirstOk.run([fn -> raise "boom" end])
      {:error, :all_failed}

      iex> Resiliency.FirstOk.run([])
      {:error, :empty}

  Typical usage — cache / DB / API fallback:

      Resiliency.FirstOk.run([
        fn -> fetch_from_cache(key) end,
        fn -> fetch_from_db(key) end,
        fn -> fetch_from_api(key) end
      ])

  """

  @type task_fun :: (-> any())

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

      iex> Resiliency.FirstOk.run([fn -> :hello end])
      {:ok, :hello}

      iex> Resiliency.FirstOk.run([
      ...>   fn -> {:error, :miss} end,
      ...>   fn -> {:ok, "found"} end
      ...> ])
      {:ok, "found"}

      iex> Resiliency.FirstOk.run([fn -> raise "boom" end])
      {:error, :all_failed}

      iex> Resiliency.FirstOk.run([])
      {:error, :empty}

  """
  @spec run([task_fun()], keyword()) :: {:ok, any()} | {:error, :all_failed | :empty}
  def run(funs, opts \\ [])

  def run([], _opts), do: {:error, :empty}

  def run(funs, opts) do
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

  defp remaining_timeout(:infinity, _elapsed), do: :infinity
  defp remaining_timeout(timeout, elapsed), do: max(timeout - elapsed, 0)

  defp timed_out?(:infinity), do: false
  defp timed_out?(t) when t <= 0, do: true
  defp timed_out?(_t), do: false
end
