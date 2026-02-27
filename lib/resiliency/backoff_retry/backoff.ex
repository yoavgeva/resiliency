defmodule Resiliency.BackoffRetry.Backoff do
  @moduledoc """
  Stream-based backoff strategies for `Resiliency.BackoffRetry`.

  Each strategy returns an infinite `Stream` of delay values in milliseconds.
  Strategies compose naturally via pipes:

      Resiliency.BackoffRetry.Backoff.exponential(base: 200)
      |> Resiliency.BackoffRetry.Backoff.jitter(0.25)
      |> Resiliency.BackoffRetry.Backoff.cap(10_000)

  ## How it works

  Every strategy is implemented with `Stream.unfold/2` or `Stream.repeatedly/1`,
  producing an infinite lazy enumerable. Because streams are lazy, no delays are
  computed until consumed — typically by `Enum.take/2` inside
  `Resiliency.BackoffRetry.retry/2`.

  **Exponential** — Each delay is the previous delay multiplied by a growth
  factor (`:multiplier`, default 2). The sequence is `base, base * m, base * m^2,
  base * m^3, ...`. Formally, the k-th delay (0-indexed) is
  `d(k) = base * multiplier^k`. This strategy spreads retries further and further
  apart, which is ideal when the downstream service needs progressively more time
  to recover.

  **Linear** — Each delay is the previous delay plus a fixed increment. The
  sequence is `base, base + inc, base + 2*inc, ...`. Formally,
  `d(k) = base + k * increment`. Growth is steady and predictable — useful when
  you want moderate back-pressure without the aggressive growth of exponential.

  **Constant** — Every delay is the same value: `delay, delay, delay, ...`.
  Formally, `d(k) = delay` for all k. Best suited for idempotent health-check
  pings or scenarios where the expected recovery time is roughly fixed.

  **Jitter** — A decorator that adds uniform random noise to each delay value.
  Given a proportion `p`, each delay `d` is replaced by a random value drawn
  uniformly from `[d * (1 - p), d * (1 + p)]`, floored at 0. Jitter prevents
  the "thundering herd" problem where many clients retry at exactly the same
  instant.

  **Cap** — A decorator that clamps each delay to a maximum value:
  `min(d, max_delay)`. This ensures no single sleep exceeds a practical ceiling
  regardless of how fast the underlying strategy grows.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `exponential/1` | O(1) to create the stream; O(1) per element consumed | O(1) — constant state in the stream accumulator |
  | `linear/1` | O(1) to create the stream; O(1) per element consumed | O(1) |
  | `constant/1` | O(1) to create the stream; O(1) per element consumed | O(1) |
  | `jitter/2` | O(1) per element consumed | O(1) |
  | `cap/2` | O(1) per element consumed | O(1) |
  """

  @doc """
  Produces an exponential backoff stream: `base`, `base * mult`, `base * mult^2`, ...

  ## Parameters

  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:base` -- initial delay in milliseconds. Defaults to `100`.
    * `:multiplier` -- growth factor applied each iteration. Defaults to `2`.

  ## Returns

  An infinite `Stream` of delay values in milliseconds, growing exponentially.

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

  ## Parameters

  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:base` -- initial delay in milliseconds. Defaults to `100`.
    * `:increment` -- additive step per retry in milliseconds. Defaults to `100`.

  ## Returns

  An infinite `Stream` of delay values in milliseconds, growing linearly.

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

  ## Parameters

  * `opts` -- keyword list of options. Defaults to `[]`.
    * `:delay` -- fixed delay in milliseconds. Defaults to `100`.

  ## Returns

  An infinite `Stream` that repeatedly emits the same delay value in milliseconds.

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

  ## Parameters

  * `delays` -- an `Enumerable` of delay values in milliseconds (typically a `Stream` from another backoff function).
  * `proportion` -- the jitter fraction, controlling how much each delay can vary. Defaults to `0.25`.

  ## Returns

  A `Stream` of jittered delay values in milliseconds.

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

  ## Parameters

  * `delays` -- an `Enumerable` of delay values in milliseconds (typically a `Stream` from another backoff function).
  * `max_delay` -- the maximum delay in milliseconds. Any delay exceeding this value is clamped to it.

  ## Returns

  A `Stream` of delay values in milliseconds, each capped at `max_delay`.

  ## Examples

      iex> Resiliency.BackoffRetry.Backoff.exponential(base: 1000) |> Resiliency.BackoffRetry.Backoff.cap(5000) |> Enum.take(5)
      [1000, 2000, 4000, 5000, 5000]

  """
  @spec cap(Enumerable.t(), non_neg_integer()) :: Enumerable.t()
  def cap(delays, max_delay) do
    Stream.map(delays, fn delay -> min(delay, max_delay) end)
  end
end
