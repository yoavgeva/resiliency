defmodule Resiliency.Hedged.Percentile do
  @moduledoc """
  Circular buffer for latency samples with percentile calculation.

  Uses `:queue` for O(1) FIFO insertion and eviction. A sorted list is
  cached on write so that percentile queries are O(1) lookups.

  ## How it works

  The buffer maintains two parallel representations of the same data:

  1. **`:queue` (FIFO order)** — An Erlang `:queue` that preserves insertion
     order. When the buffer is full (size equals `max_size`), the oldest
     element is dequeued before the new element is enqueued. This gives O(1)
     amortized insertion and eviction.

  2. **Sorted list + tuple (value order)** — A plain Elixir list kept in
     ascending sorted order, plus a pre-built tuple copy of that list. On
     each `add/2`, the evicted value (if any) is removed from the sorted
     list via a linear scan, and the new value is inserted at its sorted
     position via another linear scan. The sorted list is then converted to
     a tuple with `List.to_tuple/1`.

  Percentile queries use the tuple for O(1) indexed access. Given a
  percentile `p` (0--100) and buffer size `n`, the index is computed as
  `ceil(p / 100 * n) - 1`, clamped to `[0, n - 1]`. The value at that
  index in the sorted tuple is the answer. This avoids sorting on every
  query — the cost is paid once on write instead.

  The trade-off is intentional: writes are O(n) due to the sorted-list
  maintenance, but queries are O(1). In the hedged-request use case, writes
  happen once per completed request while queries happen once per incoming
  request — so fast queries matter more.

  ## Algorithm Complexity

  | Function | Time | Space |
  |---|---|---|
  | `new/1` | O(1) | O(1) |
  | `add/2` | O(n) where n = current buffer size — linear scan for sorted insert and (when full) sorted delete, plus O(n) `List.to_tuple/1` | O(n) — queue, sorted list, and sorted tuple each hold at most `max_size` elements |
  | `query/2` | O(1) — single `elem/2` call on the pre-built tuple | O(1) |
  """

  defstruct samples: :queue.new(), size: 0, max_size: 1000, sorted: [], sorted_tuple: {}

  @typedoc "Circular buffer holding latency samples for percentile queries."
  @type t :: %__MODULE__{
          samples: any(),
          size: non_neg_integer(),
          max_size: pos_integer(),
          sorted: [number()],
          sorted_tuple: tuple()
        }

  @doc """
  Creates a new percentile buffer with the given maximum size.

  ## Parameters

  * `max_size` -- the maximum number of latency samples the buffer will hold. Must be a positive integer. Defaults to `1000`.

  ## Returns

  A new `Resiliency.Hedged.Percentile.t()` struct with an empty sample buffer.

  ## Raises

  Raises `FunctionClauseError` if `max_size` is not a positive integer.

  ## Examples

      iex> buf = Resiliency.Hedged.Percentile.new()
      iex> buf.max_size
      1000

      iex> buf = Resiliency.Hedged.Percentile.new(50)
      iex> buf.max_size
      50

  """
  @spec new(pos_integer()) :: t()
  def new(max_size \\ 1000) when is_integer(max_size) and max_size > 0 do
    %__MODULE__{max_size: max_size}
  end

  @doc """
  Adds a sample value to the buffer, evicting the oldest if full.

  ## Parameters

  * `buf` -- a `Resiliency.Hedged.Percentile.t()` struct representing the current buffer.
  * `value` -- a number (the latency sample) to add to the buffer.

  ## Returns

  An updated `Resiliency.Hedged.Percentile.t()` struct with the new sample added. If the buffer was already at capacity, the oldest sample is evicted first.

  ## Examples

      iex> buf = Resiliency.Hedged.Percentile.new() |> Resiliency.Hedged.Percentile.add(42)
      iex> buf.size
      1

      iex> buf = Resiliency.Hedged.Percentile.new(2) |> Resiliency.Hedged.Percentile.add(1) |> Resiliency.Hedged.Percentile.add(2) |> Resiliency.Hedged.Percentile.add(3)
      iex> buf.size
      2

  """
  @spec add(t(), number()) :: t()
  def add(%__MODULE__{size: size, max_size: max_size} = buf, value) when size < max_size do
    new_sorted = sorted_insert(buf.sorted, value)

    %{
      buf
      | samples: :queue.in(value, buf.samples),
        size: size + 1,
        sorted: new_sorted,
        sorted_tuple: List.to_tuple(new_sorted)
    }
  end

  def add(%__MODULE__{max_size: max_size} = buf, value) when buf.size == max_size do
    {{:value, evicted}, trimmed} = :queue.out(buf.samples)
    new_sorted = buf.sorted |> sorted_delete(evicted) |> sorted_insert(value)

    %{
      buf
      | samples: :queue.in(value, trimmed),
        sorted: new_sorted,
        sorted_tuple: List.to_tuple(new_sorted)
    }
  end

  @doc """
  Computes the given percentile (0--100) from the buffered samples.

  Returns `nil` if the buffer is empty.

  ## Parameters

  * `buf` -- a `Resiliency.Hedged.Percentile.t()` struct containing latency samples.
  * `p` -- the percentile to compute, a number between `0` and `100` (inclusive).

  ## Returns

  The computed percentile value as a number, or `nil` if the buffer is empty.

  ## Raises

  Raises `FunctionClauseError` if `p` is not a number between `0` and `100`.

  ## Examples

      iex> Resiliency.Hedged.Percentile.query(Resiliency.Hedged.Percentile.new(), 50)
      nil

      iex> buf = Enum.reduce(1..100, Resiliency.Hedged.Percentile.new(), &Resiliency.Hedged.Percentile.add(&2, &1))
      iex> Resiliency.Hedged.Percentile.query(buf, 50)
      50

      iex> buf = Enum.reduce(1..100, Resiliency.Hedged.Percentile.new(), &Resiliency.Hedged.Percentile.add(&2, &1))
      iex> Resiliency.Hedged.Percentile.query(buf, 95)
      95

  """
  @spec query(t(), number()) :: number() | nil
  def query(%__MODULE__{size: 0}, _p), do: nil

  def query(%__MODULE__{sorted_tuple: sorted_tuple, size: size}, p)
      when is_number(p) and p >= 0 and p <= 100 do
    index =
      case p do
        0 -> 0
        _ -> min(ceil(p / 100.0 * size) - 1, size - 1)
      end

    elem(sorted_tuple, index)
  end

  # Insert value into a sorted list, maintaining sort order. O(n).
  defp sorted_insert([], value), do: [value]
  defp sorted_insert([h | t], value) when value <= h, do: [value, h | t]
  defp sorted_insert([h | t], value), do: [h | sorted_insert(t, value)]

  # Delete first occurrence of value from a sorted list. O(n).
  defp sorted_delete([], _value), do: []
  defp sorted_delete([value | t], value), do: t
  defp sorted_delete([h | t], value), do: [h | sorted_delete(t, value)]
end
