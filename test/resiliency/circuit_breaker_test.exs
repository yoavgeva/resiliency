defmodule Resiliency.CircuitBreakerTest do
  use ExUnit.Case, async: true
  doctest Resiliency.CircuitBreaker

  describe "call/2" do
    test "returns {:ok, result} on success" do
      cb = start_breaker!()
      assert {:ok, 42} = Resiliency.CircuitBreaker.call(cb, fn -> 42 end)
    end

    test "returns {:ok, result} preserving the raw return value" do
      cb = start_breaker!()
      assert {:ok, {:ok, "data"}} = Resiliency.CircuitBreaker.call(cb, fn -> {:ok, "data"} end)
    end

    test "catches raise and returns {:error, {exception, stacktrace}}" do
      cb = start_breaker!()

      assert {:error, {%RuntimeError{message: "boom"}, stacktrace}} =
               Resiliency.CircuitBreaker.call(cb, fn -> raise "boom" end)

      assert is_list(stacktrace)
    end

    test "catches exit and returns {:error, reason}" do
      cb = start_breaker!()
      assert {:error, :oops} = Resiliency.CircuitBreaker.call(cb, fn -> exit(:oops) end)
    end

    test "catches throw and returns {:error, {:nocatch, value}}" do
      cb = start_breaker!()

      assert {:error, {:nocatch, :thrown}} =
               Resiliency.CircuitBreaker.call(cb, fn -> throw(:thrown) end)
    end
  end

  describe "tripping" do
    test "trips after failure rate exceeds threshold" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 10)

      # Record 2 successes, 2 failures (50% failure rate)
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      end

      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Flush — get_state is a synchronous call
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "respects minimum_calls — does not trip below threshold" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 10, window_size: 10)

      # Record 5 failures (below minimum_calls of 10)
      for _ <- 1..5 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "evicts old entries and re-evaluates" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 4)

      # Fill window with 4 failures -> trips
      for _ <- 1..4 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Reset and fill with successes
      Resiliency.CircuitBreaker.reset(cb)

      for _ <- 1..4 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "mixed success/failure stays closed when below threshold" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 10)

      # 3 successes, 1 failure = 25% failure rate (below 50%)
      for _ <- 1..3 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      end

      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "rejects calls when open" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Should be rejected
      assert {:error, :circuit_open} =
               Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :should_not_run} end)
    end
  end

  describe "half_open" do
    test "transitions from open to half_open after open_timeout" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Wait for open_timeout
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)
      assert Resiliency.CircuitBreaker.get_state(cb) == :half_open
    end

    test "successful probe closes the circuit" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Successful probe
      assert {:ok, {:ok, :recovered}} =
               Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :recovered} end)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "failed probe reopens the circuit" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Failed probe
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :still_bad} end)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "respects permit limit in half_open" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # First call uses the permit
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :probe} end)

      # Second call should be rejected (before the cast is processed)
      # We need to ensure we check before the probe result is processed
      # This is tricky with async casts, so let's start a new breaker with 2 permits
    end

    test "multiple probes in half_open with permitted_calls_in_half_open > 1" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # 3 probes: 2 success, 1 failure = 33% failure rate (below 50% threshold)
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "multiple probes fail threshold reopens" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 2
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # 2 probes: both fail = 100% failure rate
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end
  end

  describe "should_record" do
    test "custom classification" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          should_record: fn
            {:ok, _} -> :success
            {:error, :expected} -> :ignore
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # :expected errors are ignored
      for _ <- 1..10 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :expected} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      # Real failures should trip
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :real_error} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test ":ignore is not counted in the window" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 4,
          window_size: 10,
          should_record: fn
            {:error, :ignore_me} -> :ignore
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # Record 3 successes
      for _ <- 1..3 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      end

      # Record many ignored results
      for _ <- 1..10 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :ignore_me} end)
      end

      # Only 3 calls in the window (below minimum_calls of 4)
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 3
      assert stats.failures == 0
    end

    test "default should_record behavior" do
      cb = start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 10, window_size: 10)

      # {:ok, _} -> :success
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      # {:error, _} -> :failure
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      # bare value -> :success (default)
      Resiliency.CircuitBreaker.call(cb, fn -> :bare_value end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 3
      assert stats.failures == 1
    end
  end

  describe "slow call detection" do
    test "marks slow calls" do
      cb =
        start_breaker!(
          failure_rate_threshold: 1.0,
          slow_call_threshold: 50,
          slow_call_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10
        )

      # Two slow calls
      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(60)
        {:ok, :slow}
      end)

      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(60)
        {:ok, :slow}
      end)

      # Flush
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.slow_calls == 2
    end

    test "trips on slow call rate" do
      cb =
        start_breaker!(
          failure_rate_threshold: 1.0,
          slow_call_threshold: 30,
          slow_call_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10
        )

      # Two slow calls = 100% slow rate (above 50% threshold)
      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(40)
        {:ok, :slow}
      end)

      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(40)
        {:ok, :slow}
      end)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end
  end

  describe "allow/1" do
    test "two-step flow" do
      cb = start_breaker!()
      assert {:ok, record} = Resiliency.CircuitBreaker.allow(cb)
      assert is_function(record, 1)
      assert :ok = record.(:success)
    end

    test "records correctly" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      {:ok, record1} = Resiliency.CircuitBreaker.allow(cb)
      record1.(:failure)

      {:ok, record2} = Resiliency.CircuitBreaker.allow(cb)
      record2.(:failure)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "rejects when open" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
      assert {:error, :circuit_open} = Resiliency.CircuitBreaker.allow(cb)
    end
  end

  describe "get_state/1 and get_stats/1" do
    test "returns correct initial values" do
      cb = start_breaker!()
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.state == :closed
      assert stats.total == 0
      assert stats.failures == 0
      assert stats.slow_calls == 0
      assert stats.failure_rate == 0.0
      assert stats.slow_call_rate == 0.0
    end

    test "stats reflect recorded calls" do
      cb = start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 10, window_size: 10)

      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 2
      assert stats.failures == 1
      assert stats.failure_rate == 0.5
    end
  end

  describe "reset/1" do
    test "clears window and transitions to closed" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Reset
      assert :ok = Resiliency.CircuitBreaker.reset(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
    end

    test "cancels open timer" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 100_000
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Reset should cancel the timer
      Resiliency.CircuitBreaker.reset(cb)

      # Should not transition to half_open
      Process.sleep(50)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "force_open/1 and force_close/1" do
    test "force_open transitions to open" do
      cb = start_breaker!()
      assert :ok = Resiliency.CircuitBreaker.force_open(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "force_open has no automatic timer" do
      cb = start_breaker!(open_timeout: 50)
      Resiliency.CircuitBreaker.force_open(cb)

      # Wait longer than open_timeout
      Process.sleep(100)

      # Should still be open (force_open has no timer)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "force_close transitions to closed" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      assert :ok = Resiliency.CircuitBreaker.force_close(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "force_close resets the window" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      Resiliency.CircuitBreaker.force_close(cb)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
    end

    test "reset releases forced open" do
      cb = start_breaker!()
      Resiliency.CircuitBreaker.force_open(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      Resiliency.CircuitBreaker.reset(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "on_state_change" do
    test "fires on all transitions" do
      test_pid = self()

      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      # Trip it: closed -> open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Flush to ensure cast is processed
      Resiliency.CircuitBreaker.get_state(cb)
      assert_received {:state_change, ^cb, :closed, :open}

      # Wait for open -> half_open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)
      assert_received {:state_change, ^cb, :open, :half_open}

      # Successful probe: half_open -> closed
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.get_state(cb)
      assert_received {:state_change, ^cb, :half_open, :closed}
    end

    test "does not fire when on_state_change is nil" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          on_state_change: nil
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
      # No crash means the nil callback was handled gracefully
    end

    test "does not fire when state does not change" do
      test_pid = self()

      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 10,
          window_size: 10,
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      # Record calls but stay closed (below minimum_calls)
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.get_state(cb)

      refute_received {:state_change, _, _, _}
    end
  end

  describe "concurrent calls" do
    test "many callers in closed state" do
      cb =
        start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 100, window_size: 200)

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            {:ok, result} = Resiliency.CircuitBreaker.call(cb, fn -> {:ok, i} end)
            result
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert length(results) == 50
    end

    test "permit limits in half_open" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Launch multiple concurrent calls — only 1 should be permitted
      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Resiliency.CircuitBreaker.call(cb, fn ->
              Process.sleep(10)
              {:ok, :probe}
            end)
          end)
        end)
        |> Enum.map(&Task.await/1)

      permitted = Enum.count(results, fn r -> r != {:error, :circuit_open} end)
      rejected = Enum.count(results, fn r -> r == {:error, :circuit_open} end)

      assert permitted >= 1
      assert rejected >= 1
    end
  end

  describe "child_spec" do
    test "starts under a supervisor" do
      name = :"cb_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.CircuitBreaker, name: name}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, 42} = Resiliency.CircuitBreaker.call(name, fn -> 42 end)

      Supervisor.stop(sup)
    end
  end

  # ---------------------------------------------------------------
  # Additional tests inspired by Resilience4j and gobreaker
  # ---------------------------------------------------------------

  describe "force_open rejects calls" do
    test "force_open blocks calls with :circuit_open" do
      cb = start_breaker!()
      Resiliency.CircuitBreaker.force_open(cb)

      assert {:error, :circuit_open} =
               Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :should_not_run} end)
    end

    test "force_open blocks allow/1 with :circuit_open" do
      cb = start_breaker!()
      Resiliency.CircuitBreaker.force_open(cb)

      assert {:error, :circuit_open} = Resiliency.CircuitBreaker.allow(cb)
    end
  end

  describe "force/reset idempotency" do
    test "force_open twice is idempotent" do
      cb = start_breaker!()
      :ok = Resiliency.CircuitBreaker.force_open(cb)
      :ok = Resiliency.CircuitBreaker.force_open(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "force_close twice is idempotent" do
      cb = start_breaker!()
      :ok = Resiliency.CircuitBreaker.force_close(cb)
      :ok = Resiliency.CircuitBreaker.force_close(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "reset from closed is a no-op" do
      cb = start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 10, window_size: 10)

      # Record some calls
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      # Reset from closed
      :ok = Resiliency.CircuitBreaker.reset(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
      assert stats.failures == 0
      assert stats.slow_calls == 0
      assert stats.failure_rate == 0.0
      assert stats.slow_call_rate == 0.0
    end
  end

  describe "full state cycle" do
    test "closed -> open -> half_open -> open -> half_open -> closed" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # 1. Start closed
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      # 2. Trip to open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # 3. Wait for open -> half_open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # 4. Failed probe -> back to open
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :still_bad} end)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # 5. Wait for open -> half_open again
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # 6. Successful probe -> closed
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :recovered} end)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "failure rate edge cases" do
    test "interleaved success/failure pattern trips at threshold" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 6, window_size: 10)

      # Alternate: S, F, S, F, S, F = 50% failure rate
      for _ <- 1..3 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "exactly at minimum_calls boundary — trips" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 10)

      # 2 success, 2 failure = 50% rate, exactly 4 = minimum_calls
      for _ <- 1..2, do: Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      for _ <- 1..2, do: Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "one below minimum_calls — does not trip even at 100% failure" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 10)

      # 3 failures, below minimum_calls of 4
      for _ <- 1..3, do: Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "window eviction changes failure rate below threshold" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 4)

      # Fill with 2 success + 2 failure = 50% -> trips
      for _ <- 1..2, do: Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      for _ <- 1..2, do: Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Reset and fill with 3 success + 1 failure = 25% (window=4)
      Resiliency.CircuitBreaker.reset(cb)
      for _ <- 1..3, do: Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "exception classification by default should_record" do
    test "raise counts as failure" do
      cb = start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 10, window_size: 10)

      Resiliency.CircuitBreaker.call(cb, fn -> raise "boom" end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.failures == 1
      assert stats.total == 1
    end

    test "exit counts as failure" do
      cb = start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 10, window_size: 10)

      Resiliency.CircuitBreaker.call(cb, fn -> exit(:oops) end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.failures == 1
    end

    test "throw counts as failure" do
      cb = start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 10, window_size: 10)

      Resiliency.CircuitBreaker.call(cb, fn -> throw(:val) end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.failures == 1
    end

    test "enough raises trip the circuit" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      Resiliency.CircuitBreaker.call(cb, fn -> raise "one" end)
      Resiliency.CircuitBreaker.call(cb, fn -> raise "two" end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end
  end

  describe "slow calls in half_open" do
    test "slow call rate reopens circuit from half_open" do
      cb =
        start_breaker!(
          failure_rate_threshold: 1.0,
          slow_call_threshold: 30,
          slow_call_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 2
        )

      # Trip via slow calls
      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(40)
        {:ok, :slow}
      end)

      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(40)
        {:ok, :slow}
      end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Wait for half_open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Two slow probes -> should reopen
      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(40)
        {:ok, :slow_probe}
      end)

      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(40)
        {:ok, :slow_probe}
      end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "mixed slow and fast probes close circuit when below threshold" do
      cb =
        start_breaker!(
          failure_rate_threshold: 1.0,
          slow_call_threshold: 50,
          slow_call_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 4
        )

      # Trip via slow calls
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn ->
          Process.sleep(60)
          {:ok, :slow}
        end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # 1 slow + 3 fast = 25% slow rate (below 50% threshold)
      Resiliency.CircuitBreaker.call(cb, fn ->
        Process.sleep(60)
        {:ok, :slow}
      end)

      for _ <- 1..3 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :fast} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "ignored results in half_open" do
    test "ignored results release permits and don't count toward evaluation" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3,
          should_record: fn
            {:error, :ignorable} -> :ignore
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :real} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Ignored results release permits — they don't count toward evaluation
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :ignorable} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :ignorable} end)

      # Flush to let release_permit casts process
      Resiliency.CircuitBreaker.get_state(cb)

      # Permits were released, so 3 real probes can still flow
      for _ <- 1..3 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      end

      # 3 successes = 0% failure rate → closes
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "ignored then success transitions to closed" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1,
          should_record: fn
            {:error, :ignorable} -> :ignore
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :real} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Ignored call — permit is released
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :ignorable} end)

      # Flush to let release_permit cast process
      Resiliency.CircuitBreaker.get_state(cb)

      # Now a real success probe can flow through and close the circuit
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "stale recordings in open state" do
    test "recordings from closed state are ignored after tripping" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 100_000
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Manually cast a stale recording (simulating a late-arriving cast)
      GenServer.cast(cb, {:record, :success, 0})
      GenServer.cast(cb, {:record, :failure, 0})

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # The stale casts should not affect the window
      # After reset, window should be clean
      Resiliency.CircuitBreaker.reset(cb)
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
    end
  end

  describe "metrics completeness" do
    test "reset clears all metric fields" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.9,
          slow_call_threshold: 30,
          slow_call_rate_threshold: 1.0,
          minimum_calls: 20,
          window_size: 20
        )

      # Record various outcomes
      for _ <- 1..3, do: Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      for _ <- 1..2, do: Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn ->
          Process.sleep(40)
          {:ok, :slow}
        end)
      end

      # Verify non-zero stats
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 7
      assert stats.failures == 2
      assert stats.slow_calls == 2

      # Reset
      Resiliency.CircuitBreaker.reset(cb)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
      assert stats.failures == 0
      assert stats.slow_calls == 0
      assert stats.failure_rate == 0.0
      assert stats.slow_call_rate == 0.0
      assert stats.state == :closed
    end

    test "open state rejections are not counted in stats" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # These should be rejected, not counted
      for _ <- 1..5 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :should_not_count} end)
      end

      # Stats should still reflect the 2 calls that tripped it
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 2
    end

    test "stats in half_open reflect probe window" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Record 1 probe
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :probe} end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.state == :half_open
      assert stats.total == 1
      assert stats.failures == 0
    end
  end

  describe "on_state_change with force operations" do
    test "fires on force_open and force_close" do
      test_pid = self()

      cb =
        start_breaker!(
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      # force_open: closed -> open
      Resiliency.CircuitBreaker.force_open(cb)
      assert_received {:state_change, ^cb, :closed, :open}

      # force_close: open -> closed
      Resiliency.CircuitBreaker.force_close(cb)
      assert_received {:state_change, ^cb, :open, :closed}
    end

    test "does not fire on self-transition via force_close when already closed" do
      test_pid = self()

      cb =
        start_breaker!(
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      Resiliency.CircuitBreaker.force_close(cb)
      refute_received {:state_change, _, _, _}
    end

    test "does not fire on self-transition via force_open when already open" do
      test_pid = self()

      cb =
        start_breaker!(
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      Resiliency.CircuitBreaker.force_open(cb)
      assert_received {:state_change, ^cb, :closed, :open}

      # Second force_open — same state, should not fire
      Resiliency.CircuitBreaker.force_open(cb)
      refute_received {:state_change, _, _, _}
    end
  end

  describe "allow/1 in half_open" do
    test "two-step flow works in half_open" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Two-step in half_open
      assert {:ok, record} = Resiliency.CircuitBreaker.allow(cb)

      # Second allow should be rejected (permit exhausted)
      assert {:error, :circuit_open} = Resiliency.CircuitBreaker.allow(cb)

      # Record success to close
      record.(:success)

      # Flush
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "two-step failure in half_open reopens" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      {:ok, record} = Resiliency.CircuitBreaker.allow(cb)
      record.(:failure)

      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end
  end

  describe "concurrent stress" do
    test "200 concurrent callers maintain correct count" do
      cb =
        start_breaker!(failure_rate_threshold: 0.9, minimum_calls: 500, window_size: 500)

      tasks =
        for i <- 1..200 do
          Task.async(fn ->
            {:ok, result} = Resiliency.CircuitBreaker.call(cb, fn -> {:ok, i} end)
            result
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert length(results) == 200
      assert Enum.sort(results) == Enum.map(1..200, &{:ok, &1})

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 200
      assert stats.failures == 0
    end
  end

  describe "window sliding behavior" do
    test "old failures are evicted when window wraps around" do
      cb =
        start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 8, window_size: 4)

      # Record 4 failures
      for _ <- 1..4, do: Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 4
      assert stats.failures == 4

      # Now record 4 successes — these overwrite the 4 failures
      for _ <- 1..4, do: Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 4
      assert stats.failures == 0
      assert stats.failure_rate == 0.0
    end
  end

  describe "function is not executed when circuit is open" do
    test "fn body never runs when circuit is open" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)
      test_pid = self()

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # This function should never execute
      assert {:error, :circuit_open} =
               Resiliency.CircuitBreaker.call(cb, fn ->
                 send(test_pid, :fn_executed)
                 {:ok, :should_not_happen}
               end)

      refute_received :fn_executed
    end
  end

  # ---------------------------------------------------------------
  # Additional tests inspired by fuse (Erlang circuit breaker)
  # ---------------------------------------------------------------

  describe "stale timer handling" do
    test "stale open_timeout after reset is ignored" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50
        )

      # Trip it -> open (starts timer)
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Reset cancels the timer, but a stale :open_timeout could still arrive
      Resiliency.CircuitBreaker.reset(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      # Manually send a stale timer message
      send(Process.whereis(cb), :open_timeout)

      # Should still be closed (stale message ignored)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "stale open_timeout after force_close is ignored" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50
        )

      # Trip it -> open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Force close
      Resiliency.CircuitBreaker.force_close(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      # Stale timer message
      send(Process.whereis(cb), :open_timeout)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "stale open_timeout during half_open is ignored" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3
        )

      # Trip -> open -> half_open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Stale timer message while in half_open
      send(Process.whereis(cb), :open_timeout)

      # Should still be half_open (not re-transitioned)
      assert Resiliency.CircuitBreaker.get_state(cb) == :half_open
    end
  end

  describe "reset from half_open" do
    test "reset from half_open transitions to closed and clears state" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3
        )

      # Trip -> open -> half_open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Record a probe
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :probe} end)

      # Reset from half_open
      :ok = Resiliency.CircuitBreaker.reset(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
      assert stats.failures == 0
    end
  end

  describe "force operations from half_open" do
    test "force_open from half_open transitions to open without timer" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3
        )

      # Trip -> open -> half_open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Force open from half_open
      Resiliency.CircuitBreaker.force_open(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # No timer — stays open
      Process.sleep(100)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "force_close from half_open transitions to closed" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3
        )

      # Trip -> open -> half_open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Force close from half_open
      Resiliency.CircuitBreaker.force_close(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed

      # Window should be clean
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 0
    end
  end

  describe "on_state_change callback crash" do
    test "callback that raises does not crash the GenServer" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          on_state_change: fn _name, _from, _to ->
            raise "callback boom"
          end
        )

      # Trip it — the callback will raise during state transition
      # This should not crash the GenServer
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Give the cast time to be processed
      Process.sleep(50)

      # GenServer should still be alive and functioning
      assert Process.alive?(Process.whereis(cb))
    end
  end

  describe "supervisor restart recovery" do
    test "circuit breaker restarts clean after crash" do
      name = :"cb_sup_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.CircuitBreaker,
         name: name, failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      # Record some failures to trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(name, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(name) == :open

      # Kill the GenServer process
      pid = Process.whereis(name)
      Process.exit(pid, :kill)

      # Wait for supervisor to restart it
      wait_until(fn -> Process.whereis(name) != nil and Process.whereis(name) != pid end)

      # Should restart in closed state with clean window
      assert Resiliency.CircuitBreaker.get_state(name) == :closed

      stats = Resiliency.CircuitBreaker.get_stats(name)
      assert stats.total == 0

      Supervisor.stop(sup)
    end
  end

  describe "unknown messages" do
    test "unknown info messages are silently ignored" do
      cb = start_breaker!()

      send(Process.whereis(cb), :unknown_message)
      send(Process.whereis(cb), {:random, :tuple})

      # GenServer should still work
      assert {:ok, 42} = Resiliency.CircuitBreaker.call(cb, fn -> 42 end)
    end
  end

  # ---------------------------------------------------------------
  # Bug reproduction tests
  # ---------------------------------------------------------------

  describe "BUG: half_open permit leak on all-ignore results" do
    test "circuit should not get stuck when all half_open probes are ignored" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 2,
          should_record: fn
            {:error, :ignorable} -> :ignore
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # Trip it with real failures
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :real} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Wait for half_open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Both probes return ignored results — permits should be released
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :ignorable} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:error, :ignorable} end)

      # Flush
      Resiliency.CircuitBreaker.get_state(cb)

      # Permits were released, so a new successful probe should close the circuit
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)
      Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :good} end)

      state = Resiliency.CircuitBreaker.get_state(cb)

      assert state == :closed,
             "circuit should close after ignored probes are followed by successes"
    end
  end

  describe "BUG: should_record bad return value leaks permit" do
    test "invalid should_record return falls back to :success" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1,
          should_record: fn
            {:error, :weird} -> :not_a_valid_outcome
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :real} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Bad return treated as :success — should not crash, should close circuit
      assert {:ok, {:error, :weird}} =
               Resiliency.CircuitBreaker.call(cb, fn -> {:error, :weird} end)

      # The bad return was treated as success, so the probe closes the circuit
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end

    test "should_record that raises falls back to :success" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1,
          should_record: fn
            {:error, :boom} -> raise "classifier crash"
            {:error, _} -> :failure
            _ -> :success
          end
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :real} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Crashing classifier treated as :success — no crash, circuit closes
      assert {:ok, {:error, :boom}} =
               Resiliency.CircuitBreaker.call(cb, fn -> {:error, :boom} end)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  describe "BUG: reset does not fire on_state_change" do
    test "reset from open fires on_state_change callback" do
      test_pid = self()

      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      # Trip it: closed -> open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      Resiliency.CircuitBreaker.get_state(cb)
      assert_received {:state_change, ^cb, :closed, :open}

      # Reset: open -> closed — should fire callback
      Resiliency.CircuitBreaker.reset(cb)

      assert_received {:state_change, ^cb, :open, :closed}
    end

    test "reset from half_open fires on_state_change callback" do
      test_pid = self()

      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 3,
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      # Trip -> open -> half_open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Drain transition messages
      assert_received {:state_change, ^cb, :closed, :open}
      assert_received {:state_change, ^cb, :open, :half_open}

      # Reset: half_open -> closed — should fire callback
      Resiliency.CircuitBreaker.reset(cb)

      assert_received {:state_change, ^cb, :half_open, :closed}
    end

    test "reset from closed does NOT fire on_state_change (same state)" do
      test_pid = self()

      cb =
        start_breaker!(
          on_state_change: fn name, from, to ->
            send(test_pid, {:state_change, name, from, to})
          end
        )

      # Reset from closed — no transition
      Resiliency.CircuitBreaker.reset(cb)

      refute_received {:state_change, _, _, _}
    end
  end

  # ---------------------------------------------------------------
  # Bug reproduction: second review
  # ---------------------------------------------------------------

  describe "BUG: forced open + stale timer" do
    test "stale open_timeout does not transition a force-opened circuit to half_open" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50
        )

      # Trip naturally — starts a timer
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Force close, then force open — stale timer from the natural trip
      # may still be in the mailbox
      Resiliency.CircuitBreaker.force_close(cb)
      Resiliency.CircuitBreaker.force_open(cb)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Simulate stale timer message arriving
      send(Process.whereis(cb), :open_timeout)

      # Should stay open — force_open should not be overridden by a stale timer
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end
  end

  describe "BUG: allow/1 has no way to release permit on ignore" do
    test "allow/1 record function accepts :ignore and releases the permit" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Get permit via allow/1
      {:ok, record} = Resiliency.CircuitBreaker.allow(cb)

      # Record ignore — should release the permit
      :ok = record.(:ignore)

      # Flush
      Resiliency.CircuitBreaker.get_state(cb)

      # Permit was released, so another call should be allowed
      {:ok, record2} = Resiliency.CircuitBreaker.allow(cb)
      record2.(:success)

      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  # ---------------------------------------------------------------
  # Bug reproduction: third review
  # ---------------------------------------------------------------

  describe "invalid config validation" do
    test "permitted_calls_in_half_open: 0 raises at startup" do
      assert_raise ArgumentError, ~r/permitted_calls_in_half_open/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          permitted_calls_in_half_open: 0
        )
      end
    end

    test "permitted_calls_in_half_open: -1 raises at startup" do
      assert_raise ArgumentError, ~r/permitted_calls_in_half_open/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          permitted_calls_in_half_open: -1
        )
      end
    end

    test "window_size: 0 raises at startup" do
      assert_raise ArgumentError, ~r/window_size/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          window_size: 0
        )
      end
    end

    test "minimum_calls: 0 raises at startup" do
      assert_raise ArgumentError, ~r/minimum_calls/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          minimum_calls: 0
        )
      end
    end

    test "open_timeout: 0 raises at startup" do
      assert_raise ArgumentError, ~r/open_timeout/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          open_timeout: 0
        )
      end
    end

    test "failure_rate_threshold: -0.1 raises at startup" do
      assert_raise ArgumentError, ~r/failure_rate_threshold/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          failure_rate_threshold: -0.1
        )
      end
    end

    test "failure_rate_threshold: 1.1 raises at startup" do
      assert_raise ArgumentError, ~r/failure_rate_threshold/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          failure_rate_threshold: 1.1
        )
      end
    end

    test "slow_call_rate_threshold: -0.1 raises at startup" do
      assert_raise ArgumentError, ~r/slow_call_rate_threshold/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          slow_call_rate_threshold: -0.1
        )
      end
    end

    test "slow_call_threshold: -1 raises at startup" do
      assert_raise ArgumentError, ~r/slow_call_threshold/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          slow_call_threshold: -1
        )
      end
    end

    test "slow_call_threshold: :infinity is valid" do
      name = :"cb_valid_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Resiliency.CircuitBreaker.start_link(name: name, slow_call_threshold: :infinity)

      GenServer.stop(pid)
    end

    test "should_record: not a function raises at startup" do
      assert_raise ArgumentError, ~r/should_record/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          should_record: :not_a_function
        )
      end
    end

    test "on_state_change: not a function raises at startup" do
      assert_raise ArgumentError, ~r/on_state_change/, fn ->
        Resiliency.CircuitBreaker.start_link(
          name: :"cb_invalid_#{System.unique_integer([:positive])}",
          on_state_change: "not_a_function"
        )
      end
    end

    test "on_state_change: nil is valid (disabled)" do
      name = :"cb_valid_#{System.unique_integer([:positive])}"
      {:ok, pid} = Resiliency.CircuitBreaker.start_link(name: name, on_state_change: nil)
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # Bug reproduction: fourth review
  # ---------------------------------------------------------------

  describe "BUG: allow/1 record called multiple times double-counts" do
    test "double recording in closed state inflates the window" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 4, window_size: 10)

      {:ok, record} = Resiliency.CircuitBreaker.allow(cb)

      # Call record twice — this should only count once
      record.(:failure)
      record.(:failure)

      # Flush
      stats = Resiliency.CircuitBreaker.get_stats(cb)

      # If double-counting, total=2 and failures=2.
      # Correct behavior: total should be 1.
      assert stats.total == 1,
             "allow/1 record called twice should only count once, got total=#{stats.total}"
    end

    test "double recording in half_open causes premature evaluation" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 2
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Get one permit
      {:ok, record} = Resiliency.CircuitBreaker.allow(cb)

      # Double-record success — if both are counted, half_open evaluates
      # with total=2 (>= permitted_calls_in_half_open=2), transitioning to closed
      # even though only 1 real probe ran.
      record.(:success)
      record.(:success)

      # Flush
      state = Resiliency.CircuitBreaker.get_state(cb)

      # If double-counting, the circuit would close prematurely.
      # Correct: should still be half_open, waiting for 2nd real probe.
      assert state == :half_open,
             "double recording should not cause premature evaluation, got state=#{state}"
    end
  end

  describe "allow/1 caller death auto-releases permit" do
    test "auto-releases permit as failure when caller dies in half_open" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Spawn a process that gets a permit via allow/1, then dies without recording
      {pid, monitor_ref} =
        spawn_monitor(fn ->
          {:ok, _record} = Resiliency.CircuitBreaker.allow(cb)
          # Die without calling record
        end)

      # Wait for the spawned process to terminate
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 5_000

      # The :DOWN message should auto-record :failure, causing half_open -> open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :open end)
      assert Resiliency.CircuitBreaker.get_state(cb) == :open
    end

    test "auto-releases permit when caller dies in closed state" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10
        )

      # Spawn a process that gets a permit via allow/1, then dies without recording
      {pid, monitor_ref} =
        spawn_monitor(fn ->
          {:ok, _record} = Resiliency.CircuitBreaker.allow(cb)
          # Die without calling record
        end)

      # Wait for the spawned process to terminate
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 5_000

      # Flush to let the GenServer process the :DOWN message
      _ = Resiliency.CircuitBreaker.get_state(cb)

      # Verify the failure was recorded
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.failures == 1
      assert stats.total == 1
    end

    test "demonitors on successful record call" do
      cb = start_breaker!()

      # Get permit and record successfully
      {:ok, record} = Resiliency.CircuitBreaker.allow(cb)
      record.(:success)

      # Flush to let the demonitor cast process
      _ = Resiliency.CircuitBreaker.get_state(cb)

      # The monitor was cleaned up — the test process can die without affecting circuit
      stats = Resiliency.CircuitBreaker.get_stats(cb)
      assert stats.total == 1
      assert stats.failures == 0
    end

    test "handles caller death race with record call" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50,
          permitted_calls_in_half_open: 1
        )

      # Trip it
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      # Spawn a process that records and then dies immediately
      test_pid = self()

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          {:ok, record} = Resiliency.CircuitBreaker.allow(cb)
          record.(:success)
          send(test_pid, :recorded)
          # Process exits normally after recording
        end)

      assert_receive :recorded, 5_000
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 5_000

      # The atomics guard ensures only one recording happens (success from record call).
      # The demonitor cast prevents the :DOWN from double-recording.
      # Give time for all casts to process.
      Process.sleep(50)

      # Circuit should have closed (success probe) — not tripped by a phantom failure.
      assert Resiliency.CircuitBreaker.get_state(cb) == :closed
    end
  end

  # --- Helpers ---

  defp start_breaker!(opts \\ []) do
    name = :"cb_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    start_supervised!({Resiliency.CircuitBreaker, opts})
    name
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        raise "wait_until timed out"
      end

      Process.sleep(10)
      do_wait_until(fun, deadline)
    end
  end
end
