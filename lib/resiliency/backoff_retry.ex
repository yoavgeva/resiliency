defmodule Resiliency.BackoffRetry do
  @moduledoc """
  Functional retry with backoff for Elixir.

  `Resiliency.BackoffRetry` provides a simple `retry/2` function that executes a function
  and retries on failure using composable, stream-based backoff strategies.
  Zero macros, zero processes, injectable sleep for fast tests.

  ## Quick start

      # Retry with defaults (3 attempts, exponential backoff)
      {:ok, body} = Resiliency.BackoffRetry.retry(fn -> fetch(url) end)

      # With options
      {:ok, body} = Resiliency.BackoffRetry.retry(fn -> fetch(url) end,
        backoff: :exponential,
        max_attempts: 5,
        retry_if: fn
          {:error, :timeout} -> true
          {:error, :econnrefused} -> true
          _ -> false
        end,
        on_retry: fn attempt, delay, error ->
          Logger.warning("Attempt \#{attempt} failed: \#{inspect(error)}")
        end
      )

  ## Options

    * `:backoff` — `:exponential` (default), `:linear`, `:constant`, or any `Enumerable` of ms
    * `:base_delay` — initial delay in ms (default: `100`)
    * `:max_delay` — cap per-retry delay in ms (default: `5_000`)
    * `:max_attempts` — total attempts including first (default: `3`)
    * `:budget` — total time budget in ms (default: `:infinity`)
    * `:retry_if` — `fn {:error, reason} -> boolean end` (default: retries all errors)
    * `:on_retry` — `fn attempt, delay, error -> any` callback before sleep
    * `:sleep_fn` — sleep function, defaults to `Process.sleep/1`
    * `:reraise` — `true` to re-raise rescued exceptions with original stacktrace when retries are exhausted (default: `false`)

  """

  defmodule Abort do
    @moduledoc """
    Wraps a reason to signal that retry should stop immediately.

    Return `{:error, Resiliency.BackoffRetry.abort(reason)}` from the retried function
    to abort without further attempts, regardless of `retry_if`.
    """
    defstruct [:reason]

    @type t :: %__MODULE__{reason: any()}
  end

  @type option ::
          {:backoff, :exponential | :linear | :constant | Enumerable.t()}
          | {:base_delay, non_neg_integer()}
          | {:max_delay, non_neg_integer()}
          | {:max_attempts, pos_integer()}
          | {:budget, :infinity | non_neg_integer()}
          | {:retry_if, (any() -> boolean())}
          | {:on_retry, (pos_integer(), non_neg_integer(), any() -> any())}
          | {:sleep_fn, (non_neg_integer() -> any())}
          | {:reraise, boolean()}

  @doc """
  Creates an `%Abort{}` struct to signal immediate retry termination.

  ## Example

      Resiliency.BackoffRetry.retry(fn ->
        case api_call() do
          {:error, :not_found} -> {:error, Resiliency.BackoffRetry.abort(:not_found)}
          other -> other
        end
      end)

  """
  @spec abort(any()) :: Abort.t()
  def abort(reason), do: %Abort{reason: reason}

  @doc """
  Executes `fun` and retries on failure with configurable backoff.

  See the module documentation for available options.

  With `reraise: true`, re-raises rescued exceptions with the original
  stacktrace when retries are exhausted instead of returning `{:error, exception}`.
  """
  @spec retry((-> any()), [option()]) :: {:ok, any()} | {:error, any()}
  def retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    retry_if = Keyword.get(opts, :retry_if, fn {:error, _} -> true end)
    on_retry = Keyword.get(opts, :on_retry)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    budget = Keyword.get(opts, :budget, :infinity)
    reraise = Keyword.get(opts, :reraise, false)

    delays = build_delays(opts, max_attempts)

    deadline =
      case budget do
        :infinity -> :infinity
        ms -> System.monotonic_time(:millisecond) + ms
      end

    ctx = %{
      fun: fun,
      retry_if: retry_if,
      on_retry: on_retry,
      sleep_fn: sleep_fn,
      deadline: deadline,
      reraise: reraise
    }

    do_retry(ctx, delays, 1)
  end

  defp do_retry(ctx, delays, attempt) do
    case execute(ctx.fun) do
      {:ok, value} ->
        {:ok, value}

      {:error, %Abort{reason: reason}} ->
        {:error, reason}

      {:error, {:__rescued__, exception, stacktrace}} ->
        error = {:error, exception}
        maybe_retry(ctx, delays, attempt, exception, error, stacktrace)

      {:error, reason} = error ->
        maybe_retry(ctx, delays, attempt, reason, error, nil)
    end
  end

  defp maybe_retry(ctx, [], _attempt, reason, _error, stacktrace) do
    maybe_reraise(ctx, reason, stacktrace)
  end

  defp maybe_retry(ctx, [delay | rest], attempt, reason, error, stacktrace) do
    cond do
      not ctx.retry_if.(error) ->
        maybe_reraise(ctx, reason, stacktrace)

      budget_exceeded?(ctx.deadline, delay) ->
        maybe_reraise(ctx, reason, stacktrace)

      true ->
        if ctx.on_retry, do: ctx.on_retry.(attempt, delay, error)
        ctx.sleep_fn.(delay)
        do_retry(ctx, rest, attempt + 1)
    end
  end

  defp maybe_reraise(%{reraise: true}, exception, stacktrace)
       when is_exception(exception) and is_list(stacktrace) do
    reraise exception, stacktrace
  end

  defp maybe_reraise(_ctx, reason, _stacktrace), do: {:error, reason}

  defp execute(fun) do
    normalize(fun.())
  rescue
    e -> {:error, {:__rescued__, e, __STACKTRACE__}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  defp normalize({:ok, value}), do: {:ok, value}
  defp normalize({:error, %Abort{}} = abort), do: abort
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize({:error, %Abort{} = abort, _extra}), do: {:error, abort}
  defp normalize({:error, reason, extra}), do: {:error, {reason, extra}}
  defp normalize(:ok), do: {:ok, :ok}
  defp normalize(:error), do: {:error, :error}
  defp normalize(value), do: {:ok, value}

  defp build_delays(opts, max_attempts) do
    delays_stream = build_delay_stream(opts)

    delays_stream
    |> Resiliency.BackoffRetry.Backoff.cap(Keyword.get(opts, :max_delay, 5_000))
    |> Enum.take(max(max_attempts - 1, 0))
  end

  defp build_delay_stream(opts) do
    case Keyword.get(opts, :backoff, :exponential) do
      :exponential ->
        Resiliency.BackoffRetry.Backoff.exponential(base: Keyword.get(opts, :base_delay, 100))

      :linear ->
        Resiliency.BackoffRetry.Backoff.linear(base: Keyword.get(opts, :base_delay, 100))

      :constant ->
        Resiliency.BackoffRetry.Backoff.constant(delay: Keyword.get(opts, :base_delay, 100))

      delays when is_list(delays) ->
        delays

      %Stream{} = stream ->
        stream

      enumerable ->
        enumerable
    end
  end

  defp budget_exceeded?(:infinity, _delay), do: false

  defp budget_exceeded?(deadline, delay) do
    System.monotonic_time(:millisecond) + delay > deadline
  end
end
