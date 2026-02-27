defmodule Resiliency.SingleFlight do
  @moduledoc """
  Deduplicate concurrent function calls by key.

  When multiple processes call `flight/3` with the same key concurrently,
  only the first call executes the function. All other callers block and
  receive the same result when the function completes.

  Inspired by Go's `singleflight` package.

  ## When to use

    * Loading a popular cache key that just expired — without deduplication,
      hundreds of processes may simultaneously query the database for the same
      row ("cache stampede" / "thundering herd"). SingleFlight ensures only
      one query runs while the rest wait.
    * Fetching a remote configuration blob or feature-flag payload that many
      GenServers request at startup — deduplication avoids redundant network
      calls.
    * Resolving a DNS name or refreshing an OAuth token that several
      concurrent HTTP clients need at the same moment.
    * Any expensive or rate-limited operation keyed by a string, where
      concurrent callers can safely share a single result.

  ## How it works

  `Resiliency.SingleFlight` is backed by a GenServer that maintains a map of
  in-flight keys. When `flight/3` is called, the server checks whether the
  given key already has a running execution. If not, a new process is spawned
  to run the user function, and the caller's `from` reference is stored as
  the first waiter. If the key is already in-flight, the caller's `from` is
  appended to the existing waiter list — no new process is spawned.

  When the spawned process completes (successfully, or via raise/exit/throw),
  the server receives the result, replies to every waiting caller with the
  same value, and removes the key from the in-flight map. This means the cost
  of the underlying function is paid exactly once per key per flight window,
  regardless of how many processes called `flight/3` concurrently.

  `forget/2` removes a key from the in-flight map without cancelling the
  running execution. Existing waiters still receive the original result, but
  any new caller after `forget/2` triggers a fresh execution — useful for
  forcing a reload after a write.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `start_link/1` | O(1) | O(1) |
  | `child_spec/1` | O(1) | O(1) |
  | `flight/3` | O(1) amortized — map lookup + optional spawn | O(w) where w = number of waiters for this key |
  | `flight/4` | O(1) amortized — same as `flight/3` with a timeout | O(w) |
  | `forget/2` | O(1) — map delete | O(1) |

  ## Usage

      # Add to your supervision tree
      {Resiliency.SingleFlight, name: MyApp.Flights}

      # Deduplicated call
      {:ok, result} = Resiliency.SingleFlight.flight(MyApp.Flights, "user:123", fn ->
        Repo.get!(User, 123)
      end)

      # Evict a key so next call starts fresh
      :ok = Resiliency.SingleFlight.forget(MyApp.Flights, "user:123")
  """

  @type server :: GenServer.server()
  @type key :: term()
  @type result :: {:ok, term()} | {:error, term()}

  @doc """
  Returns a child spec for starting a `Resiliency.SingleFlight` server.

  ## Parameters

  * `opts` -- keyword list of options.
    * `:name` -- (required) the name to register the server under.

  ## Returns

  A `Supervisor.child_spec()` map suitable for inclusion in a supervision tree.

  ## Raises

  Raises `KeyError` if the required `:name` option is not provided.

  ## Examples

      children = [
        {Resiliency.SingleFlight, name: MyApp.Flights}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  Starts a `Resiliency.SingleFlight` server.

  ## Parameters

  * `opts` -- keyword list of options.
    * `:name` -- (required) the name to register the server under.

  ## Returns

  `{:ok, pid}` on success, or `{:error, reason}` if the process cannot be started.

  ## Raises

  Raises `KeyError` if the required `:name` option is not provided.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Resiliency.SingleFlight.Server.start_link(name: name)
  end

  @doc """
  Execute `fun` deduplicated by `key`.

  If no other call with the same key is in-flight, `fun` is executed.
  If another call with the same key is already in-flight, this call
  blocks until the in-flight call completes and returns the same result.

  Returns `{:ok, result}` on success or `{:error, reason}` if the
  function raises, throws, or exits.

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.SingleFlight` server.
  * `key` -- any term used to deduplicate concurrent calls.
  * `fun` -- a zero-arity function to execute.

  ## Returns

  `{:ok, result}` on success, or `{:error, reason}` if the function raises, throws, or exits.

  ## Examples

      iex> {:ok, _pid} = Resiliency.SingleFlight.start_link(name: :flight_example)
      iex> Resiliency.SingleFlight.flight(:flight_example, "key", fn -> 42 end)
      {:ok, 42}

  If the function raises, all callers receive an error:

      iex> {:ok, _pid} = Resiliency.SingleFlight.start_link(name: :flight_raise_example)
      iex> {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
      ...>   Resiliency.SingleFlight.flight(:flight_raise_example, "bad", fn -> raise "boom" end)

  """
  @spec flight(server(), key(), (-> term())) :: result()
  def flight(server, key, fun) when is_function(fun, 0) do
    GenServer.call(server, {:flight, key, fun}, :infinity)
  end

  @doc """
  Like `flight/3` but with a caller-side timeout in milliseconds.

  If the timeout expires before the function completes, the calling
  process exits with `{:timeout, _}`. The in-flight function continues
  executing and will still deliver results to other waiting callers.

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.SingleFlight` server.
  * `key` -- any term used to deduplicate concurrent calls.
  * `fun` -- a zero-arity function to execute.
  * `timeout` -- caller-side timeout in milliseconds.

  ## Returns

  `{:ok, result}` on success, or `{:error, reason}` if the function raises, throws, or exits. Exits with `{:timeout, _}` if the timeout expires before the function completes.

  ## Examples

      Resiliency.SingleFlight.flight(MyApp.Flights, "slow-key", fn ->
        :timer.sleep(5_000)
        :result
      end, 1_000)
      # ** (exit) exited in: GenServer.call/3 — timeout after 1000ms

  """
  @spec flight(server(), key(), (-> term()), timeout()) :: result()
  def flight(server, key, fun, timeout) when is_function(fun, 0) do
    GenServer.call(server, {:flight, key, fun}, timeout)
  end

  @doc """
  Forget a key so the next `flight/3` call with that key starts a fresh execution.

  If there is an in-flight call for the key, existing waiters still receive
  the original result. Only new callers after `forget/2` will trigger a
  fresh execution.

  ## Parameters

  * `server` -- the name or PID of a running `Resiliency.SingleFlight` server.
  * `key` -- the key to forget.

  ## Returns

  `:ok`. The forget is processed asynchronously via `GenServer.cast/2`.

  ## Examples

      iex> {:ok, _pid} = Resiliency.SingleFlight.start_link(name: :flight_forget_example)
      iex> Resiliency.SingleFlight.forget(:flight_forget_example, "user:123")
      :ok

  """
  @spec forget(server(), key()) :: :ok
  def forget(server, key) do
    GenServer.cast(server, {:forget, key})
  end
end
