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
end
