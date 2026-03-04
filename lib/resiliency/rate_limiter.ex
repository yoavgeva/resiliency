defmodule Resiliency.RateLimiter do
  @moduledoc """
  A token-bucket rate limiter for controlling request frequency.

  A rate limiter wraps calls to a downstream service and limits how many can
  execute per second. When the token bucket is empty, callers are rejected
  immediately with a `retry_after` hint telling them when to try again.

  Unlike `Resiliency.Bulkhead`, which controls *concurrency* (how many calls
  can be in-flight at once), the rate limiter controls *frequency*
  (requests per second). They complement each other and can be composed.

  ## When to use

    * You need to stay under a rate limit imposed by an external API or
      service (e.g., "100 requests per second").
    * You want to smooth out bursty traffic to protect a downstream system.
    * You need weighted requests — expensive operations can consume more
      tokens than lightweight ones.

  ## Quick start

      # 1. Add to your supervision tree
      children = [
        {Resiliency.RateLimiter, name: MyApp.ApiRateLimiter, rate: 100.0, burst_size: 10}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # 2. Use it
      case Resiliency.RateLimiter.call(MyApp.ApiRateLimiter, fn -> HttpClient.get(url) end) do
        {:ok, response} -> handle_response(response)
        {:error, {:rate_limited, retry_after_ms}} -> {:error, {:overloaded, retry_after_ms}}
        {:error, reason} -> {:error, reason}
      end

  ## How it works

  The rate limiter uses a **token bucket** algorithm with lazy refill — there
  is no background timer or process. Instead, tokens are refilled on each
  call based on how much time has elapsed since the last refill.

    * The bucket starts full at `burst_size` tokens.
    * Tokens refill at `rate` tokens per second (lazily on each call).
    * Each call consumes `weight` tokens (default `1`).
    * If enough tokens are available, the call proceeds immediately.
    * If not, the call is rejected with a `retry_after_ms` hint.

  Token acquisition uses a **lock-free ETS CAS loop** — callers read the
  bucket state, compute the refill, and atomically update the row via
  `:ets.select_replace/2`. On conflict (two callers racing), the loser
  retries immediately with the freshly-written state. This means:

    * No GenServer message is sent on the hot `call/2,3` path.
    * Throughput scales with the number of schedulers, not a single mailbox.
    * A lightweight GenServer owns the ETS table and handles `reset/1`.
    * The protected function runs in the **caller's process**; a crash there
      does not affect the rate limiter state.

  ## Return values

  | Function | Success | Rate limited | fn crashes |
  |---|---|---|---|
  | `call/2,3` | `{:ok, result}` | `{:error, {:rate_limited, ms}}` | `{:error, reason}` |

  Note: bare values returned by `fun` (not wrapped in `{:ok, _}` or `{:error, _}`) are
  automatically wrapped in `{:ok, value}`. This follows the `BackoffRetry` convention and
  differs from `Resiliency.Bulkhead` which returns raw results.

  ## Error handling

  If the function raises, exits, or throws, the error is caught and returned
  to the caller. The token consumed for the call is **not** refunded, as the
  call did execute:

      {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
        Resiliency.RateLimiter.call(MyApp.ApiRateLimiter, fn -> raise "boom" end)

  ## Telemetry

  All events are emitted in the caller's process. See `Resiliency.Telemetry`
  for the complete event catalogue.

  ### `[:resiliency, :rate_limiter, :call, :start]`

  Emitted at the beginning of every `call/2,3` invocation, before the token
  acquisition attempt.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `system_time` | `integer` | `System.system_time()` at emission time |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The rate limiter name passed to `call/2,3` |

  ### `[:resiliency, :rate_limiter, :call, :rejected]`

  Emitted when the token bucket is empty and the call is rejected without
  executing the function. Always followed immediately by a `:stop` event.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `retry_after` | `integer` | Milliseconds until the caller may retry |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The rate limiter name |

  ### `[:resiliency, :rate_limiter, :call, :stop]`

  Emitted after every `call/2,3` completes — whether rejected, successful,
  or failed.

  **Measurements**

  | Key | Type | Description |
  |-----|------|-------------|
  | `duration` | `integer` | Elapsed native time units (`System.monotonic_time/0` delta) |

  **Metadata**

  | Key | Type | Description |
  |-----|------|-------------|
  | `name` | `term` | The rate limiter name |
  | `result` | `:ok \\| :error` | `:ok` on success, `:error` on failure or rejection |
  | `error` | `term \\| nil` | The error reason, `{:rate_limited, ms}` if rejected, `nil` on success |

  """

  @typedoc "A rate limiter name — the atom passed as `:name` at startup."
  @type name :: atom()

  @doc """
  Returns a child specification for starting under a supervisor.

  ## Options

  * `:name` -- (required) the name to register the rate limiter under.
  * `:rate` -- (required) the refill rate in tokens per second. Must be a
    positive number.
  * `:burst_size` -- (required) the maximum number of tokens the bucket can
    hold. Also the initial number of tokens. Must be a positive integer.
  * `:on_reject` -- optional `fn name -> any` callback fired when a call is
    rejected due to rate limiting.

  ## Examples

      children = [
        {Resiliency.RateLimiter, name: MyApp.ApiRateLimiter, rate: 100.0, burst_size: 10}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      iex> spec = Resiliency.RateLimiter.child_spec(name: :my_rl, rate: 10.0, burst_size: 5)
      iex> spec.id
      {Resiliency.RateLimiter, :my_rl}

  """
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {Resiliency.RateLimiter.Server, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts a rate limiter linked to the current process.

  Typically you'd use `child_spec/1` instead to start under a supervisor.
  See `child_spec/1` for options.

  ## Examples

      {:ok, pid} = Resiliency.RateLimiter.start_link(
        name: MyApp.ApiRateLimiter,
        rate: 100.0,
        burst_size: 10
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Resiliency.RateLimiter.Server.start_link(opts)
  end

  @doc """
  Executes `fun` through the rate limiter.

  If enough tokens are available in the bucket, the function runs in the
  caller's process and tokens are consumed. If the bucket is empty,
  returns `{:error, {:rate_limited, retry_after_ms}}` without executing
  the function.

  ## Parameters

  * `name` -- the name or PID of a running rate limiter.
  * `fun` -- a zero-arity function to execute.
  * `opts` -- optional keyword list.
    * `:weight` -- the number of tokens to consume. Must be a positive
      integer. Defaults to `1`.

  ## Returns

  `{:ok, result}` on success, `{:error, {:rate_limited, retry_after_ms}}`
  when rate limited, or `{:error, reason}` if the function raises, exits,
  or throws.

  ## Examples

      iex> {:ok, _pid} = Resiliency.RateLimiter.start_link(name: :call_rl, rate: 100.0, burst_size: 10)
      iex> Resiliency.RateLimiter.call(:call_rl, fn -> 1 + 1 end)
      {:ok, 2}

  """
  @spec call(name(), (-> result)) :: {:ok, result} | {:error, term()} when result: term()
  @spec call(name(), (-> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: term()
  def call(name, fun, opts \\ []) when is_function(fun, 0) do
    weight = Keyword.get(opts, :weight, 1)
    validate_weight!(weight)

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:resiliency, :rate_limiter, :call, :start],
      %{system_time: System.system_time()},
      %{name: name}
    )

    case Resiliency.RateLimiter.Server.acquire(name, weight) do
      {:error, {:rate_limited, retry_after_ms}} ->
        :telemetry.execute(
          [:resiliency, :rate_limiter, :call, :rejected],
          %{retry_after: retry_after_ms},
          %{name: name}
        )

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:resiliency, :rate_limiter, :call, :stop],
          %{duration: duration},
          %{name: name, result: :error, error: {:rate_limited, retry_after_ms}}
        )

        {:error, {:rate_limited, retry_after_ms}}

      {:ok, :granted} ->
        {raw_result, error_info} = execute(fun)
        duration = System.monotonic_time() - start_time

        case error_info do
          nil ->
            :telemetry.execute(
              [:resiliency, :rate_limiter, :call, :stop],
              %{duration: duration},
              %{name: name, result: :ok, error: nil}
            )

            normalize(raw_result)

          err ->
            :telemetry.execute(
              [:resiliency, :rate_limiter, :call, :stop],
              %{duration: duration},
              %{name: name, result: :error, error: err}
            )

            {:error, err}
        end
    end
  end

  @doc """
  Returns statistics about the rate limiter.

  The token count is computed read-only — this call does **not** consume
  tokens or update the refill timestamp.

  ## Returns

  A map containing:
  * `:tokens` -- the current (projected) number of tokens available
  * `:rate` -- the configured refill rate in tokens per second
  * `:burst_size` -- the configured maximum bucket size

  ## Examples

      iex> {:ok, _pid} = Resiliency.RateLimiter.start_link(name: :stats_rl, rate: 10.0, burst_size: 5)
      iex> stats = Resiliency.RateLimiter.get_stats(:stats_rl)
      iex> stats.burst_size
      5

  """
  @spec get_stats(name()) :: map()
  def get_stats(name) do
    Resiliency.RateLimiter.Server.get_stats(name)
  end

  @doc """
  Resets the rate limiter to its initial state (full bucket).

  ## Examples

      iex> {:ok, _pid} = Resiliency.RateLimiter.start_link(name: :reset_rl, rate: 10.0, burst_size: 5)
      iex> Resiliency.RateLimiter.reset(:reset_rl)
      :ok

  """
  @spec reset(name()) :: :ok
  def reset(name) do
    GenServer.call(Resiliency.RateLimiter.Server.via_name(name), :reset)
  end

  defp validate_weight!(weight) when is_integer(weight) and weight >= 1, do: :ok

  defp validate_weight!(weight) do
    raise ArgumentError,
          "weight must be a positive integer, got: #{inspect(weight)}"
  end

  defp execute(fun) do
    result = fun.()
    {result, nil}
  rescue
    e ->
      {{:error, {e, __STACKTRACE__}}, {e, __STACKTRACE__}}
  catch
    :exit, reason ->
      {{:error, reason}, reason}

    :throw, value ->
      {{:error, {:nocatch, value}}, {:nocatch, value}}
  end

  defp normalize({:ok, _} = result), do: result
  defp normalize({:error, _} = result), do: result
  defp normalize(value), do: {:ok, value}
end
