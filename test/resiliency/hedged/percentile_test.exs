defmodule Resiliency.Hedged.PercentileTest do
  use ExUnit.Case, async: true

  alias Resiliency.Hedged.Percentile

  doctest Resiliency.Hedged.Percentile

  describe "new/1" do
    test "creates an empty buffer with default max_size" do
      buf = Percentile.new()
      assert buf.size == 0
      assert buf.max_size == 1000
    end

    test "creates an empty buffer with custom max_size" do
      buf = Percentile.new(50)
      assert buf.size == 0
      assert buf.max_size == 50
    end
  end

  describe "add/2" do
    test "adds a single sample" do
      buf = Percentile.new() |> Percentile.add(42)
      assert buf.size == 1
    end

    test "adds multiple samples" do
      buf =
        Percentile.new()
        |> Percentile.add(1)
        |> Percentile.add(2)
        |> Percentile.add(3)

      assert buf.size == 3
    end

    test "evicts oldest when full" do
      buf =
        Percentile.new(3)
        |> Percentile.add(10)
        |> Percentile.add(20)
        |> Percentile.add(30)
        |> Percentile.add(40)

      assert buf.size == 3
      # oldest (10) should be evicted, remaining: [20, 30, 40]
      assert Percentile.query(buf, 0) == 20
    end
  end

  describe "query/2" do
    test "returns nil for empty buffer" do
      assert Percentile.query(Percentile.new(), 50) == nil
    end

    test "returns the value for a single sample at any percentile" do
      buf = Percentile.new() |> Percentile.add(42)
      assert Percentile.query(buf, 0) == 42
      assert Percentile.query(buf, 50) == 42
      assert Percentile.query(buf, 100) == 42
    end

    test "computes p50 for a known distribution" do
      buf = Enum.reduce(1..100, Percentile.new(), &Percentile.add(&2, &1))
      assert Percentile.query(buf, 50) == 50
    end

    test "computes p95 for a known distribution" do
      buf = Enum.reduce(1..100, Percentile.new(), &Percentile.add(&2, &1))
      assert Percentile.query(buf, 95) == 95
    end

    test "computes p99 for a known distribution" do
      buf = Enum.reduce(1..100, Percentile.new(), &Percentile.add(&2, &1))
      assert Percentile.query(buf, 99) == 99
    end

    test "handles p0 (minimum)" do
      buf = Enum.reduce(1..100, Percentile.new(), &Percentile.add(&2, &1))
      assert Percentile.query(buf, 0) == 1
    end

    test "handles p100 (maximum)" do
      buf = Enum.reduce(1..100, Percentile.new(), &Percentile.add(&2, &1))
      assert Percentile.query(buf, 100) == 100
    end

    test "evicted buffer returns correct percentiles" do
      # Buffer of size 10, feed 20 values (1..20), keeps 11..20
      buf = Enum.reduce(1..20, Percentile.new(10), &Percentile.add(&2, &1))
      assert buf.size == 10
      assert Percentile.query(buf, 0) == 11
      assert Percentile.query(buf, 100) == 20
    end

    test "all identical values return that value for any percentile" do
      buf = Enum.reduce(1..50, Percentile.new(), fn _, b -> Percentile.add(b, 42) end)
      assert Percentile.query(buf, 0) == 42
      assert Percentile.query(buf, 50) == 42
      assert Percentile.query(buf, 99) == 42
      assert Percentile.query(buf, 100) == 42
    end

    test "two values return correct p50" do
      buf = Percentile.new() |> Percentile.add(10) |> Percentile.add(20)
      assert Percentile.query(buf, 50) == 10
      assert Percentile.query(buf, 100) == 20
    end

    test "buffer of size 1 evicts correctly" do
      buf =
        Percentile.new(1)
        |> Percentile.add(100)
        |> Percentile.add(200)

      assert buf.size == 1
      assert Percentile.query(buf, 50) == 200
    end

    test "float values are supported" do
      buf =
        Percentile.new()
        |> Percentile.add(1.5)
        |> Percentile.add(2.5)
        |> Percentile.add(3.5)

      assert Percentile.query(buf, 0) == 1.5
      assert Percentile.query(buf, 100) == 3.5
    end

    test "negative values are supported" do
      buf =
        Percentile.new()
        |> Percentile.add(-10)
        |> Percentile.add(0)
        |> Percentile.add(10)

      assert Percentile.query(buf, 0) == -10
      assert Percentile.query(buf, 100) == 10
    end

    test "large buffer (1000 samples)" do
      buf = Enum.reduce(1..1000, Percentile.new(1000), &Percentile.add(&2, &1))
      assert buf.size == 1000
      assert Percentile.query(buf, 50) == 500
      assert Percentile.query(buf, 99) == 990
    end
  end

  describe "incremental sort correctness" do
    test "large buffer (10_000 samples) with eviction" do
      buf = Enum.reduce(1..20_000, Percentile.new(10_000), &Percentile.add(&2, &1))
      assert buf.size == 10_000
      # Buffer holds 10_001..20_000
      assert Percentile.query(buf, 0) == 10_001
      assert Percentile.query(buf, 50) == 15_000
      assert Percentile.query(buf, 100) == 20_000
    end

    test "random input maintains sorted order through evictions" do
      seed = :rand.seed(:exsss, {1, 2, 3})
      :rand.seed(seed)

      buf =
        Enum.reduce(1..500, Percentile.new(100), fn _, b ->
          Percentile.add(b, :rand.uniform(10_000))
        end)

      assert buf.size == 100
      assert buf.sorted == Enum.sort(buf.sorted)
      assert length(buf.sorted) == 100
    end

    test "duplicate values are inserted and evicted correctly" do
      buf = Percentile.new(5)

      # Insert duplicates: [7, 7, 7, 3, 3]
      buf =
        buf
        |> Percentile.add(7)
        |> Percentile.add(7)
        |> Percentile.add(7)
        |> Percentile.add(3)
        |> Percentile.add(3)

      assert buf.sorted == [3, 3, 7, 7, 7]

      # Evict 7, add 3 -> queue [7, 7, 3, 3, 3], sorted [3, 3, 3, 7, 7]
      buf = Percentile.add(buf, 3)
      assert buf.sorted == [3, 3, 3, 7, 7]

      # Evict 7, add 7 -> queue [7, 3, 3, 3, 7], sorted [3, 3, 3, 7, 7]
      buf = Percentile.add(buf, 7)
      assert buf.sorted == [3, 3, 3, 7, 7]

      # Evict 7, add 1 -> queue [3, 3, 3, 7, 1], sorted [1, 3, 3, 3, 7]
      buf = Percentile.add(buf, 1)
      assert buf.sorted == [1, 3, 3, 3, 7]
    end
  end

  describe "sorted_tuple consistency" do
    test "sorted_tuple matches sorted list after each add" do
      buf =
        Enum.reduce(1..10, Percentile.new(5), fn i, b ->
          b = Percentile.add(b, i)
          assert Tuple.to_list(b.sorted_tuple) == b.sorted
          b
        end)

      assert buf.size == 5
    end

    test "sorted_tuple matches sorted list with random input and evictions" do
      :rand.seed(:exsss, {42, 42, 42})

      Enum.reduce(1..300, Percentile.new(50), fn _, b ->
        b = Percentile.add(b, :rand.uniform(1000))
        assert Tuple.to_list(b.sorted_tuple) == b.sorted
        b
      end)
    end

    test "sorted_tuple is empty for a new buffer" do
      buf = Percentile.new()
      assert buf.sorted_tuple == {}
    end

    test "query uses sorted_tuple for O(1) access on a full buffer" do
      buf = Enum.reduce(1..100, Percentile.new(100), &Percentile.add(&2, &1))

      # Verify tuple has correct length and content
      assert tuple_size(buf.sorted_tuple) == 100
      assert elem(buf.sorted_tuple, 0) == 1
      assert elem(buf.sorted_tuple, 49) == 50
      assert elem(buf.sorted_tuple, 99) == 100

      # And query returns the same values
      assert Percentile.query(buf, 0) == 1
      assert Percentile.query(buf, 50) == 50
      assert Percentile.query(buf, 100) == 100
    end
  end

  describe "cached sorted list consistency" do
    test "sorted list stays consistent after add/eviction cycles" do
      buf = Percentile.new(5)

      buf = Enum.reduce(1..20, buf, fn i, b -> Percentile.add(b, i) end)

      # Buffer should contain 16..20, sorted: [16, 17, 18, 19, 20]
      assert buf.size == 5
      assert buf.sorted == [16, 17, 18, 19, 20]
      assert Percentile.query(buf, 0) == 16
      assert Percentile.query(buf, 100) == 20
    end

    test "sorted list correct after non-sequential insertions with evictions" do
      buf = Percentile.new(3)

      buf =
        buf
        |> Percentile.add(50)
        |> Percentile.add(10)
        |> Percentile.add(30)
        |> Percentile.add(5)
        |> Percentile.add(40)

      # Buffer contains: [30, 5, 40] (10 and 50 evicted)
      assert buf.size == 3
      assert buf.sorted == [5, 30, 40]
      assert Percentile.query(buf, 0) == 5
      assert Percentile.query(buf, 100) == 40
    end

    test "query after multiple evictions returns correct values" do
      buf = Percentile.new(4)

      # Add 1..8, buffer keeps 5..8
      buf = Enum.reduce(1..8, buf, fn i, b -> Percentile.add(b, i) end)

      assert Percentile.query(buf, 0) == 5
      assert Percentile.query(buf, 50) == 6
      assert Percentile.query(buf, 100) == 8

      # Add more, buffer keeps 9..12 (but really 9, 10, 11, 12)
      buf = Enum.reduce(9..12, buf, fn i, b -> Percentile.add(b, i) end)

      assert Percentile.query(buf, 0) == 9
      assert Percentile.query(buf, 100) == 12
    end
  end
end
