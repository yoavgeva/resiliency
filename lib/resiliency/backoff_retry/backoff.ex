defmodule Resiliency.BackoffRetry.Backoff do
  @moduledoc """
  Stream-based backoff strategies for `Resiliency.BackoffRetry`.

  Each strategy returns an infinite `Stream` of delay values in milliseconds.
  Strategies compose naturally via pipes:

      Resiliency.BackoffRetry.Backoff.exponential(base: 200)
      |> Resiliency.BackoffRetry.Backoff.jitter(0.25)
      |> Resiliency.BackoffRetry.Backoff.cap(10_000)

  """

  @doc """
  Produces an exponential backoff stream: `base`, `base * mult`, `base * mult^2`, ...

  ## Options

    * `:base` — initial delay in ms (default: `100`)
    * `:multiplier` — growth factor (default: `2`)

  ## Examples

      iex> Resiliency.BackoffRetry.Backoff.exponential() |> Enum.take(4)
      [100, 200, 400, 800]

      iex> Resiliency.BackoffRetry.Backoff.exponential(base: 50, multiplier: 3) |> Enum.take(3)
      [50, 150, 450]

  """
  @spec exponential(keyword()) :: Enumerable.t()
  def exponential(opts \\ []) do
    base = Keyword.get(opts, :base, 100)
    multiplier = Keyword.get(opts, :multiplier, 2)

    Stream.unfold(base, fn delay ->
      {delay, delay * multiplier}
    end)
  end

  @doc """
  Produces a linear backoff stream: `base`, `base + inc`, `base + 2*inc`, ...

  ## Options

    * `:base` — initial delay in ms (default: `100`)
    * `:increment` — additive step per retry (default: `100`)

  ## Examples

      iex> Resiliency.BackoffRetry.Backoff.linear() |> Enum.take(4)
      [100, 200, 300, 400]

      iex> Resiliency.BackoffRetry.Backoff.linear(base: 50, increment: 50) |> Enum.take(3)
      [50, 100, 150]

  """
  @spec linear(keyword()) :: Enumerable.t()
  def linear(opts \\ []) do
    base = Keyword.get(opts, :base, 100)
    increment = Keyword.get(opts, :increment, 100)

    Stream.unfold(base, fn delay ->
      {delay, delay + increment}
    end)
  end

  @doc """
  Produces a constant backoff stream: `delay`, `delay`, `delay`, ...

  ## Options

    * `:delay` — fixed delay in ms (default: `100`)

  ## Examples

      iex> Resiliency.BackoffRetry.Backoff.constant() |> Enum.take(3)
      [100, 100, 100]

      iex> Resiliency.BackoffRetry.Backoff.constant(delay: 500) |> Enum.take(3)
      [500, 500, 500]

  """
  @spec constant(keyword()) :: Enumerable.t()
  def constant(opts \\ []) do
    delay = Keyword.get(opts, :delay, 100)
    Stream.repeatedly(fn -> delay end)
  end

  @doc """
  Adds random jitter to each delay value.

  Each delay `d` becomes a random value in `[d * (1 - proportion), d * (1 + proportion)]`,
  floored at `0`.

  ## Examples

      Resiliency.BackoffRetry.Backoff.exponential()
      |> Resiliency.BackoffRetry.Backoff.jitter(0.25)

  """
  @spec jitter(Enumerable.t(), float()) :: Enumerable.t()
  def jitter(delays, proportion \\ 0.25) do
    Stream.map(delays, fn delay ->
      min_val = delay * (1 - proportion)
      max_val = delay * (1 + proportion)
      jittered = min_val + :rand.uniform() * (max_val - min_val)
      max(0, round(jittered))
    end)
  end

  @doc """
  Caps each delay at `max_delay` milliseconds.

  ## Examples

      iex> Resiliency.BackoffRetry.Backoff.exponential(base: 1000) |> Resiliency.BackoffRetry.Backoff.cap(5000) |> Enum.take(5)
      [1000, 2000, 4000, 5000, 5000]

  """
  @spec cap(Enumerable.t(), non_neg_integer()) :: Enumerable.t()
  def cap(delays, max_delay) do
    Stream.map(delays, fn delay -> min(delay, max_delay) end)
  end
end
