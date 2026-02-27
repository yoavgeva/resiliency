defmodule Resiliency.SingleFlight do
  @moduledoc """
  Deduplicate concurrent function calls by key.

  When multiple processes call `flight/3` with the same key concurrently,
  only the first call executes the function. All other callers block and
  receive the same result when the function completes.

  Inspired by Go's `singleflight` package.

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

  ## Options

    * `:name` - (required) the name to register the server under

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

  ## Options

    * `:name` - (required) the name to register the server under

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
