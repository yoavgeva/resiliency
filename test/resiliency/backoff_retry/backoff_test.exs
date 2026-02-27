defmodule Resiliency.BackoffRetry.BackoffTest do
  use ExUnit.Case, async: true

  alias Resiliency.BackoffRetry.Backoff

  doctest Resiliency.BackoffRetry.Backoff

  describe "exponential/1" do
    test "produces correct default sequence" do
      assert Backoff.exponential() |> Enum.take(5) == [100, 200, 400, 800, 1600]
    end

    test "respects base option" do
      assert Backoff.exponential(base: 50) |> Enum.take(3) == [50, 100, 200]
    end

    test "respects multiplier option" do
      assert Backoff.exponential(base: 10, multiplier: 3) |> Enum.take(4) == [10, 30, 90, 270]
    end

    test "returns an infinite stream" do
      assert Backoff.exponential() |> Enum.take(20) |> length() == 20
    end
  end

  describe "linear/1" do
    test "produces correct default sequence" do
      assert Backoff.linear() |> Enum.take(4) == [100, 200, 300, 400]
    end

    test "respects base option" do
      assert Backoff.linear(base: 50) |> Enum.take(3) == [50, 150, 250]
    end

    test "respects increment option" do
      assert Backoff.linear(base: 10, increment: 50) |> Enum.take(4) == [10, 60, 110, 160]
    end
  end

  describe "constant/1" do
    test "produces correct default sequence" do
      assert Backoff.constant() |> Enum.take(3) == [100, 100, 100]
    end

    test "respects delay option" do
      assert Backoff.constant(delay: 500) |> Enum.take(3) == [500, 500, 500]
    end
  end

  describe "jitter/2" do
    test "values stay within bounds" do
      base_delays = Backoff.constant(delay: 1000)
      proportion = 0.25

      jittered = base_delays |> Backoff.jitter(proportion) |> Enum.take(1000)

      for delay <- jittered do
        assert delay >= 750
        assert delay <= 1250
      end
    end

    test "produces non-negative values" do
      # Small base to test floor at 0
      jittered = Backoff.constant(delay: 1) |> Backoff.jitter(0.99) |> Enum.take(100)

      for delay <- jittered do
        assert delay >= 0
      end
    end

    test "introduces variance" do
      jittered = Backoff.constant(delay: 1000) |> Backoff.jitter(0.25) |> Enum.take(100)
      unique_values = Enum.uniq(jittered)
      # With 100 samples and jitter, we should get many distinct values
      assert length(unique_values) > 1
    end

    test "default proportion is 0.25" do
      jittered = Backoff.constant(delay: 1000) |> Backoff.jitter() |> Enum.take(1000)

      for delay <- jittered do
        assert delay >= 750
        assert delay <= 1250
      end
    end
  end

  describe "cap/2" do
    test "limits values above cap" do
      capped = Backoff.exponential(base: 1000) |> Backoff.cap(5000) |> Enum.take(5)
      assert capped == [1000, 2000, 4000, 5000, 5000]
    end

    test "preserves values below cap" do
      capped = Backoff.exponential(base: 10) |> Backoff.cap(5000) |> Enum.take(3)
      assert capped == [10, 20, 40]
    end
  end

  describe "jitter boundary conditions" do
    test "jitter with proportion 0.0 produces exact base values" do
      base_delays = Backoff.constant(delay: 1000)
      jittered = base_delays |> Backoff.jitter(0.0) |> Enum.take(100)

      for delay <- jittered do
        assert delay == 1000
      end
    end

    test "jitter with proportion 1.0 produces values in [0, 2*delay]" do
      base_delays = Backoff.constant(delay: 1000)
      jittered = base_delays |> Backoff.jitter(1.0) |> Enum.take(1000)

      for delay <- jittered do
        assert delay >= 0
        assert delay <= 2000
      end
    end

    test "jitter with delay 0 always returns 0" do
      jittered = Backoff.constant(delay: 0) |> Backoff.jitter(0.5) |> Enum.take(100)

      for delay <- jittered do
        assert delay == 0
      end
    end

    test "jitter mean is approximately centered on base delay" do
      base = 1000
      samples = Backoff.constant(delay: base) |> Backoff.jitter(0.25) |> Enum.take(10_000)
      mean = Enum.sum(samples) / length(samples)

      # Mean should be within 5% of base
      assert_in_delta mean, base, base * 0.05
    end
  end

  describe "exponential boundary conditions" do
    test "exponential with multiplier 1 behaves like constant" do
      delays = Backoff.exponential(base: 100, multiplier: 1) |> Enum.take(5)
      assert delays == [100, 100, 100, 100, 100]
    end
  end

  describe "cap boundary conditions" do
    test "cap with 0 produces all zeros" do
      capped = Backoff.exponential(base: 100) |> Backoff.cap(0) |> Enum.take(5)
      assert capped == [0, 0, 0, 0, 0]
    end

    test "large exponential values are correctly capped" do
      max_delay = 5000

      capped =
        Backoff.exponential(base: 1, multiplier: 10)
        |> Backoff.cap(max_delay)
        |> Enum.take(30)

      for delay <- capped do
        assert delay <= max_delay
        assert delay >= 0
      end

      # Early values should be below cap
      assert hd(capped) == 1
      # Later values should all be capped
      assert List.last(capped) == max_delay
    end
  end

  describe "composition" do
    test "exponential |> jitter |> cap" do
      delays =
        Backoff.exponential(base: 100)
        |> Backoff.jitter(0.1)
        |> Backoff.cap(500)
        |> Enum.take(10)

      assert length(delays) == 10

      for delay <- delays do
        assert delay >= 0
        assert delay <= 500
      end
    end
  end
end
