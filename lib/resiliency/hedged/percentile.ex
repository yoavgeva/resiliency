defmodule Resiliency.Hedged.Percentile do
  @moduledoc """
  Circular buffer for latency samples with percentile calculation.

  Uses `:queue` for O(1) FIFO insertion and eviction. Percentile queries
  sort the buffer contents (O(n log n) for n up to `max_size`).
  """

  defstruct samples: :queue.new(), size: 0, max_size: 1000

  @typedoc "Circular buffer holding latency samples for percentile queries."
  @type t :: %__MODULE__{
          samples: any(),
          size: non_neg_integer(),
          max_size: pos_integer()
        }

  @doc """
  Creates a new percentile buffer with the given maximum size.

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
    %{buf | samples: :queue.in(value, buf.samples), size: size + 1}
  end

  def add(%__MODULE__{max_size: max_size} = buf, value) when buf.size == max_size do
    {_, trimmed} = :queue.out(buf.samples)
    %{buf | samples: :queue.in(value, trimmed)}
  end

  @doc """
  Computes the given percentile (0–100) from the buffered samples.

  Returns `nil` if the buffer is empty.

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

  def query(%__MODULE__{samples: samples, size: size}, p)
      when is_number(p) and p >= 0 and p <= 100 do
    sorted = samples |> :queue.to_list() |> Enum.sort()

    index =
      case p do
        0 -> 0
        _ -> min(ceil(p / 100.0 * size) - 1, size - 1)
      end

    Enum.at(sorted, index)
  end
end
