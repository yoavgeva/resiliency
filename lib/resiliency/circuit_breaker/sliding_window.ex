defmodule Resiliency.CircuitBreaker.SlidingWindow do
  @moduledoc false

  defstruct [:size, :buffer, index: 0, total: 0, failures: 0, slow_calls: 0]

  @doc """
  Creates a new sliding window with the given `size`.
  """
  def new(size) when is_integer(size) and size > 0 do
    %__MODULE__{
      size: size,
      buffer: :array.new(size, default: nil)
    }
  end

  @doc """
  Records an outcome into the sliding window.

  `outcome` is `:success` or `:failure`. `slow?` indicates whether the call
  was slow. Returns the updated window.
  """
  def record(%__MODULE__{} = window, outcome, slow? \\ false)
      when outcome in [:success, :failure] and is_boolean(slow?) do
    old = :array.get(window.index, window.buffer)
    buffer = :array.set(window.index, {outcome, slow?}, window.buffer)

    {failures, slow_calls, total} =
      decrement_old(old, window.failures, window.slow_calls, window.total)

    failures = if outcome == :failure, do: failures + 1, else: failures
    slow_calls = if slow?, do: slow_calls + 1, else: slow_calls
    total = min(total + 1, window.size)

    %__MODULE__{
      window
      | buffer: buffer,
        index: rem(window.index + 1, window.size),
        total: total,
        failures: failures,
        slow_calls: slow_calls
    }
  end

  @doc """
  Returns the failure rate as a float between 0.0 and 1.0.

  Returns 0.0 when no calls have been recorded.
  """
  def failure_rate(%__MODULE__{total: 0}), do: 0.0
  def failure_rate(%__MODULE__{} = w), do: w.failures / w.total

  @doc """
  Returns the slow call rate as a float between 0.0 and 1.0.

  Returns 0.0 when no calls have been recorded.
  """
  def slow_call_rate(%__MODULE__{total: 0}), do: 0.0
  def slow_call_rate(%__MODULE__{} = w), do: w.slow_calls / w.total

  @doc """
  Resets the window, clearing all recorded outcomes.
  """
  def reset(%__MODULE__{} = window) do
    %__MODULE__{
      window
      | buffer: :array.new(window.size, default: nil),
        index: 0,
        total: 0,
        failures: 0,
        slow_calls: 0
    }
  end

  @doc """
  Returns a map of current statistics.
  """
  def stats(%__MODULE__{} = w) do
    %{
      total: w.total,
      failures: w.failures,
      slow_calls: w.slow_calls,
      failure_rate: failure_rate(w),
      slow_call_rate: slow_call_rate(w)
    }
  end

  # Decrements counters based on the old value being evicted from the slot.
  defp decrement_old(nil, failures, slow_calls, total) do
    {failures, slow_calls, total}
  end

  defp decrement_old({old_outcome, old_slow?}, failures, slow_calls, total) do
    failures = if old_outcome == :failure, do: failures - 1, else: failures
    slow_calls = if old_slow?, do: slow_calls - 1, else: slow_calls
    # total stays the same when evicting (we're replacing, not adding)
    # but we decrement by 1 so the +1 below brings it back
    {failures, slow_calls, total - 1}
  end
end
