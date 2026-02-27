defmodule Resiliency.WeightedSemaphore do
  @moduledoc """
  A weighted semaphore for bounding concurrent access to a shared resource.

  Unlike a standard semaphore where each acquisition takes one permit,
  a weighted semaphore allows each acquisition to specify a weight — the
  number of permits it consumes. This is useful when different operations
  have different costs (e.g., a bulk insert costs more than a single read).

  Inspired by Go's [`x/sync/semaphore`](https://pkg.go.dev/golang.org/x/sync/semaphore),
  with an Elixir-idiomatic API that auto-releases permits when the function
  completes or crashes — eliminating permit leaks entirely.

  ## When to use

    * Limiting concurrent database connections from a pool of workers — each
      query costs 1 permit, a bulk import costs N permits, ensuring the total
      never exceeds the connection limit.
    * Throttling outbound HTTP requests to a rate-limited third-party API —
      e.g., allowing at most 5 concurrent calls to a payment gateway.
    * Bounding memory-intensive operations such as image processing or CSV
      parsing where each job has a different memory footprint — assign weight
      proportional to estimated memory so the system stays within safe limits.
    * Protecting a shared file system or disk queue from too many concurrent
      writers, where a large batch write should block smaller writes to avoid
      I/O contention.

  ## Quick start

      # 1. Add to your supervision tree
      children = [
        {Resiliency.WeightedSemaphore, name: MyApp.Sem, max: 10}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # 2. Use it
      {:ok, user} = Resiliency.WeightedSemaphore.acquire(MyApp.Sem, fn ->
        Repo.get!(User, 123)
      end)

  ## How it works

  When you call `acquire/2`, the semaphore checks if enough permits are
  available. If so, it runs your function in a separate process and returns
  the result. If not, your caller blocks (FIFO queue) until permits are freed.

  When the function finishes — whether it returns normally, raises, exits,
  or throws — permits are automatically released and the next queued caller
  is woken up.

  ## Fairness

  Waiters are served in strict FIFO order. When a large waiter is at the
  front of the queue but not enough permits are available, smaller waiters
  behind it also block — even if they would fit. This prevents starvation
  of large requests.

  For example, with `max: 10` and 5 permits free: if a weight-8 request
  is first in queue, a weight-1 request behind it will also wait, ensuring
  the weight-8 request gets served once enough permits free up.

  ## Return values

  | Function | Success | No capacity | Timeout | fn crashes | Weight > max |
  |---|---|---|---|---|---|
  | `acquire/2,3` | `{:ok, result}` | blocks | — | `{:error, reason}` | `{:error, :weight_exceeds_max}` |
  | `acquire/4` | `{:ok, result}` | blocks | `{:error, :timeout}` | `{:error, reason}` | `{:error, :weight_exceeds_max}` |
  | `try_acquire/2,3` | `{:ok, result}` | `:rejected` | — | `{:error, reason}` | `{:error, :weight_exceeds_max}` |

  ## Error handling

  If the function raises, exits, or throws, the permits are still released
  and the error is returned to the caller:

      # raise → {:error, {%RuntimeError{}, stacktrace}}
      {:error, {%RuntimeError{message: "boom"}, _}} =
        Resiliency.WeightedSemaphore.acquire(MyApp.Sem, fn -> raise "boom" end)

      # exit → {:error, reason}
      {:error, :oops} =
        Resiliency.WeightedSemaphore.acquire(MyApp.Sem, fn -> exit(:oops) end)

  In all cases, permits are freed and the next queued caller proceeds.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `start_link/1` | O(1) | O(1) |
  | `child_spec/1` | O(1) | O(1) |
  | `acquire/2` | O(1) GenServer call + O(q) queue drain on release, where q = queued waiters | O(q) — one entry per queued waiter |
  | `acquire/3,4` | O(1) GenServer call + O(q) queue drain on release | O(q) |
  | `try_acquire/2` | O(1) — immediate accept or reject, no queue interaction | O(1) |
  | `try_acquire/3` | O(1) | O(1) |
  """

  @typedoc "A semaphore reference — a registered name, PID, or `{:via, ...}` tuple."
  @type name :: GenServer.server()

  @typedoc "The number of permits to acquire. Must be a positive integer not exceeding the semaphore's max."
  @type weight :: pos_integer()

  @doc """
  Returns a child specification for starting under a supervisor.

  ## Parameters

  * `opts` -- keyword list of options.
    * `:name` -- (required) the name to register the semaphore under.
    * `:max` -- (required) the maximum total weight (number of permits).

  ## Returns

  A `Supervisor.child_spec()` map suitable for inclusion in a supervision tree.

  ## Raises

  Raises `KeyError` if the required `:name` option is not provided.

  ## Examples

      # In your Application or Supervisor
      children = [
        {Resiliency.WeightedSemaphore, name: MyApp.Sem, max: 10},
        {Resiliency.WeightedSemaphore, name: MyApp.ApiThrottle, max: 5}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      iex> spec = Resiliency.WeightedSemaphore.child_spec(name: :my_sem, max: 10)
      iex> spec.id
      {Resiliency.WeightedSemaphore, :my_sem}

  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {Resiliency.WeightedSemaphore.Server, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts a weighted semaphore linked to the current process.

  Typically you'd use `child_spec/1` instead to start under a supervisor.
  See `child_spec/1` for options.

  ## Parameters

  * `opts` -- keyword list of options.
    * `:name` -- (required) the name to register the semaphore under.
    * `:max` -- (required) the maximum total weight (number of permits).

  ## Returns

  `{:ok, pid}` on success, or `{:error, reason}` if the process cannot be started.

  ## Examples

      {:ok, pid} = Resiliency.WeightedSemaphore.start_link(name: MyApp.Sem, max: 10)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Resiliency.WeightedSemaphore.Server.start_link(opts)
  end

  @doc """
  Acquires 1 permit, runs `fun`, and auto-releases the permit.

  Blocks until a permit is available. The function runs in a separate
  process — if it raises, exits, or throws, the error is returned and
  permits are still released.

  ## Parameters

  * `sem` -- the name or PID of a running `Resiliency.WeightedSemaphore` server.
  * `fun` -- a zero-arity function to execute once the permit is acquired.

  ## Returns

  `{:ok, result}` on success, or `{:error, reason}` if the function raises, exits, or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.WeightedSemaphore.start_link(name: :acq1_sem, max: 3)
      iex> Resiliency.WeightedSemaphore.acquire(:acq1_sem, fn -> 1 + 1 end)
      {:ok, 2}

  """
  @spec acquire(name(), (-> result)) :: {:ok, result} | {:error, term()} when result: term()
  def acquire(sem, fun) when is_function(fun, 0) do
    acquire(sem, 1, fun)
  end

  @doc """
  Acquires `weight` permits, runs `fun`, and auto-releases the permits.

  Blocks until enough permits are available. If `timeout` is given (in
  milliseconds), returns `{:error, :timeout}` if permits aren't available
  in time.

  Returns `{:error, :weight_exceeds_max}` immediately if `weight` is larger
  than the semaphore's total capacity.

  ## Parameters

  * `sem` -- the name or PID of a running `Resiliency.WeightedSemaphore` server.
  * `weight` -- the number of permits to acquire. Must be a positive integer.
  * `fun` -- a zero-arity function to execute once the permits are acquired.
  * `timeout` -- optional caller-side timeout in milliseconds or `:infinity`. Defaults to `:infinity`.

  ## Returns

  `{:ok, result}` on success, `{:error, :weight_exceeds_max}` if `weight` exceeds the semaphore's max capacity, `{:error, :timeout}` if the timeout expires before permits are available, or `{:error, reason}` if the function raises, exits, or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.WeightedSemaphore.start_link(name: :acq3_sem, max: 10)
      iex> Resiliency.WeightedSemaphore.acquire(:acq3_sem, 3, fn -> :done end)
      {:ok, :done}

      iex> {:ok, _pid} = Resiliency.WeightedSemaphore.start_link(name: :acq3_max_sem, max: 5)
      iex> Resiliency.WeightedSemaphore.acquire(:acq3_max_sem, 6, fn -> :never end)
      {:error, :weight_exceeds_max}

  """
  @spec acquire(name(), weight(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  @spec acquire(name(), weight(), (-> result), timeout()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def acquire(sem, weight, fun, timeout \\ :infinity)
      when is_integer(weight) and is_function(fun, 0) do
    GenServer.call(sem, {:acquire, weight, fun}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Tries to acquire 1 permit without blocking.

  If a permit is available and no one is queued ahead, runs `fun` and
  returns `{:ok, result}`. Otherwise returns `:rejected` immediately.

  This is useful for "best effort" work that can be skipped when the
  system is under load.

  ## Parameters

  * `sem` -- the name or PID of a running `Resiliency.WeightedSemaphore` server.
  * `fun` -- a zero-arity function to execute if the permit is acquired.

  ## Returns

  `{:ok, result}` on success, `:rejected` if no permit is available or there are waiters in the queue, or `{:error, reason}` if the function raises, exits, or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.WeightedSemaphore.start_link(name: :try1_sem, max: 3)
      iex> Resiliency.WeightedSemaphore.try_acquire(:try1_sem, fn -> :fast end)
      {:ok, :fast}

  """
  @spec try_acquire(name(), (-> result)) :: {:ok, result} | {:error, term()} | :rejected
        when result: term()
  def try_acquire(sem, fun) when is_function(fun, 0) do
    try_acquire(sem, 1, fun)
  end

  @doc """
  Tries to acquire `weight` permits without blocking.

  If enough permits are available and no one is queued ahead, runs `fun`
  and returns `{:ok, result}`. Otherwise returns `:rejected` immediately.

  Note that `:rejected` is returned even if enough raw capacity exists
  but there are waiters in the queue — this preserves FIFO fairness.

  ## Parameters

  * `sem` -- the name or PID of a running `Resiliency.WeightedSemaphore` server.
  * `weight` -- the number of permits to acquire. Must be a positive integer.
  * `fun` -- a zero-arity function to execute if permits are acquired.

  ## Returns

  `{:ok, result}` on success, `:rejected` if insufficient permits are available or there are waiters in the queue, `{:error, :weight_exceeds_max}` if `weight` exceeds the semaphore's max capacity, or `{:error, reason}` if the function raises, exits, or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.WeightedSemaphore.start_link(name: :try3_sem, max: 5)
      iex> Resiliency.WeightedSemaphore.try_acquire(:try3_sem, 2, fn -> :ok end)
      {:ok, :ok}

      iex> {:ok, _pid} = Resiliency.WeightedSemaphore.start_link(name: :try3_max_sem, max: 5)
      iex> Resiliency.WeightedSemaphore.try_acquire(:try3_max_sem, 999, fn -> :never end)
      {:error, :weight_exceeds_max}

  """
  @spec try_acquire(name(), weight(), (-> result)) ::
          {:ok, result} | {:error, term()} | :rejected
        when result: term()
  def try_acquire(sem, weight, fun)
      when is_integer(weight) and is_function(fun, 0) do
    GenServer.call(sem, {:try_acquire, weight, fun})
  end
end
