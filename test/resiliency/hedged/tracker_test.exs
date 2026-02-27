defmodule Resiliency.Hedged.TrackerTest do
  use ExUnit.Case, async: true

  describe "start_link/1" do
    test "starts with a name" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} =
               start_supervised!({Resiliency.Hedged.Tracker, name: name}) |> then(&{:ok, &1})
    end

    test "requires :name option" do
      assert_raise KeyError, ~r/:name/, fn ->
        Resiliency.Hedged.Tracker.start_link([])
      end
    end
  end

  describe "get_config/1" do
    test "returns initial_delay before min_samples reached" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker, name: name, initial_delay: 200, min_samples: 5}
      )

      assert {200, true} = Resiliency.Hedged.Tracker.get_config(name)
    end

    test "adapts delay after enough samples" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name, min_samples: 5, percentile: 95, initial_delay: 200}
      )

      # Record 20 samples with latencies 10..30
      for i <- 10..30 do
        Resiliency.Hedged.Tracker.record(name, %{latency_ms: i, hedged?: false, hedge_won?: false})
      end

      # Allow cast to process
      _ = Resiliency.Hedged.Tracker.stats(name)

      {delay, _allow?} = Resiliency.Hedged.Tracker.get_config(name)
      # Should be around p95 of 10..30 (roughly 29-30), not the initial 200
      assert delay < 200
      assert delay >= 10
    end

    test "clamps delay to min_delay" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker, name: name, min_samples: 2, min_delay: 50, percentile: 50}
      )

      for _ <- 1..5 do
        Resiliency.Hedged.Tracker.record(name, %{latency_ms: 1, hedged?: false, hedge_won?: false})
      end

      _ = Resiliency.Hedged.Tracker.stats(name)
      {delay, _} = Resiliency.Hedged.Tracker.get_config(name)
      assert delay >= 50
    end

    test "clamps delay to max_delay" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker, name: name, min_samples: 2, max_delay: 100, percentile: 99}
      )

      for _ <- 1..10 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 5000,
          hedged?: false,
          hedge_won?: false
        })
      end

      _ = Resiliency.Hedged.Tracker.stats(name)
      {delay, _} = Resiliency.Hedged.Tracker.get_config(name)
      assert delay <= 100
    end
  end

  describe "token bucket" do
    test "tokens deplete with hedging, disabling further hedges" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         token_max: 2,
         token_success_credit: 0.0,
         token_hedge_cost: 1.0,
         token_threshold: 1.0}
      )

      # First hedge: tokens 2 -> 1, still above threshold
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: true, hedge_won?: false})
      _ = Resiliency.Hedged.Tracker.stats(name)
      {_, allow?} = Resiliency.Hedged.Tracker.get_config(name)
      assert allow? == true

      # Second hedge: tokens 1 -> 0, below threshold
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: true, hedge_won?: false})
      _ = Resiliency.Hedged.Tracker.stats(name)
      {_, allow?} = Resiliency.Hedged.Tracker.get_config(name)
      assert allow? == false
    end

    test "tokens replenish with non-hedged requests" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         token_max: 2,
         token_success_credit: 1.0,
         token_hedge_cost: 2.0,
         token_threshold: 1.0}
      )

      # Deplete tokens: 2 + 1 - 2 = 1, then another: 1 + 1 - 2 = 0
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: true, hedge_won?: false})
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: true, hedge_won?: false})
      _ = Resiliency.Hedged.Tracker.stats(name)
      {_, allow?} = Resiliency.Hedged.Tracker.get_config(name)
      assert allow? == false

      # Replenish with normal request: 0 + 1 = 1
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: false, hedge_won?: false})

      _ = Resiliency.Hedged.Tracker.stats(name)
      {_, allow?} = Resiliency.Hedged.Tracker.get_config(name)
      assert allow? == true
    end

    test "tokens do not exceed max" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name, token_max: 5, token_success_credit: 10.0, token_threshold: 1.0}
      )

      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: false, hedge_won?: false})
      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.tokens == 5.0
    end
  end

  describe "stats/1" do
    test "tracks counters correctly" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name})

      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: false, hedge_won?: false})
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 20, hedged?: true, hedge_won?: false})
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 15, hedged?: true, hedge_won?: true})

      stats = Resiliency.Hedged.Tracker.stats(name)

      assert stats.total_requests == 3
      assert stats.hedged_requests == 2
      assert stats.hedge_won == 1
    end

    test "includes percentile values" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name})

      for i <- 1..100 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: i,
          hedged?: false,
          hedge_won?: false
        })
      end

      stats = Resiliency.Hedged.Tracker.stats(name)

      assert stats.p50 == 50
      assert stats.p95 == 95
      assert stats.p99 == 99
    end

    test "returns nil percentiles when empty" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name})

      stats = Resiliency.Hedged.Tracker.stats(name)

      assert stats.p50 == nil
      assert stats.p95 == nil
      assert stats.p99 == nil
    end
  end

  describe "concurrent access" do
    test "handles many concurrent records safely" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name})

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Resiliency.Hedged.Tracker.record(name, %{
              latency_ms: i,
              hedged?: rem(i, 5) == 0,
              hedge_won?: rem(i, 10) == 0
            })
          end)
        end

      Task.await_many(tasks)

      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.total_requests == 100
      # 20 hedged (every 5th)
      assert stats.hedged_requests == 20
      # 10 hedge_won (every 10th)
      assert stats.hedge_won == 10
    end

    test "concurrent get_config and record don't deadlock" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name})

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Resiliency.Hedged.Tracker.get_config(name)
            else
              Resiliency.Hedged.Tracker.record(name, %{
                latency_ms: i,
                hedged?: false,
                hedge_won?: false
              })
            end
          end)
        end

      # Should complete without deadlock
      Task.await_many(tasks, 5_000)
      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.total_requests == 50
    end
  end

  describe "token bucket (extended)" do
    test "tokens exactly at threshold allow hedging" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         token_max: 1,
         token_success_credit: 0.0,
         token_hedge_cost: 0.0,
         token_threshold: 1.0}
      )

      # tokens start at 1.0 == threshold 1.0
      {_, allow?} = Resiliency.Hedged.Tracker.get_config(name)
      assert allow? == true
    end

    test "tokens just below threshold disallow hedging" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         token_max: 1,
         token_success_credit: 0.0,
         token_hedge_cost: 0.5,
         token_threshold: 1.0}
      )

      # tokens start at 1.0, hedge costs 0.5 -> 0.5 (below threshold)
      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: true, hedge_won?: false})
      _ = Resiliency.Hedged.Tracker.stats(name)
      {_, allow?} = Resiliency.Hedged.Tracker.get_config(name)
      assert allow? == false
    end

    test "tokens do not go below zero" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         token_max: 1,
         token_success_credit: 0.0,
         token_hedge_cost: 5.0,
         token_threshold: 1.0}
      )

      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 10, hedged?: true, hedge_won?: false})
      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.tokens == 0.0
    end
  end

  describe "percentile edge cases" do
    test "all identical latencies" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker, name: name, min_samples: 2, min_delay: 1, max_delay: 5_000}
      )

      for _ <- 1..20 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 50,
          hedged?: false,
          hedge_won?: false
        })
      end

      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.p50 == 50
      assert stats.p95 == 50
      assert stats.p99 == 50
      assert stats.current_delay == 50
    end

    test "bimodal distribution" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!({Resiliency.Hedged.Tracker, name: name, min_samples: 2, percentile: 50})

      # 50 fast, 50 slow
      for _ <- 1..50 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 10,
          hedged?: false,
          hedge_won?: false
        })
      end

      for _ <- 1..50 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 1000,
          hedged?: false,
          hedge_won?: false
        })
      end

      stats = Resiliency.Hedged.Tracker.stats(name)
      # p50 should be around the boundary between fast and slow
      assert stats.p50 >= 10
      assert stats.p50 <= 1000
    end

    test "delay adapts when latency pattern changes" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         min_samples: 5,
         buffer_size: 20,
         percentile: 95,
         min_delay: 1,
         max_delay: 5_000}
      )

      # Phase 1: fast latencies
      for _ <- 1..20 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 10,
          hedged?: false,
          hedge_won?: false
        })
      end

      _ = Resiliency.Hedged.Tracker.stats(name)
      {delay_fast, _} = Resiliency.Hedged.Tracker.get_config(name)

      # Phase 2: slow latencies (evicts old fast ones)
      for _ <- 1..20 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 500,
          hedged?: false,
          hedge_won?: false
        })
      end

      _ = Resiliency.Hedged.Tracker.stats(name)
      {delay_slow, _} = Resiliency.Hedged.Tracker.get_config(name)

      assert delay_slow > delay_fast
    end

    test "min_samples: 0 adapts from the first sample" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         min_samples: 0,
         initial_delay: 500,
         min_delay: 1,
         max_delay: 5_000,
         percentile: 95}
      )

      # With 0 min_samples but empty buffer, query returns nil
      # So it falls back to initial_delay until at least 1 sample
      {delay_empty, _} = Resiliency.Hedged.Tracker.get_config(name)
      assert delay_empty == 500

      Resiliency.Hedged.Tracker.record(name, %{latency_ms: 20, hedged?: false, hedge_won?: false})
      _ = Resiliency.Hedged.Tracker.stats(name)
      {delay_one, _} = Resiliency.Hedged.Tracker.get_config(name)
      assert delay_one == 20
    end
  end

  describe "stats (extended)" do
    test "stats includes current_delay and tokens" do
      name = :"tracker_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker, name: name, initial_delay: 200, token_max: 10}
      )

      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.current_delay == 200
      assert stats.tokens == 10.0
    end

    test "tracker remains functional after recording errors" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name})

      # Record some high-latency "failed" requests
      for _ <- 1..5 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 5000,
          hedged?: true,
          hedge_won?: false
        })
      end

      # Tracker should still respond
      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.total_requests == 5
      assert stats.hedged_requests == 5

      # Can still get_config
      {_delay, _allow?} = Resiliency.Hedged.Tracker.get_config(name)
    end

    test "buffer overflow with rapid records" do
      name = :"tracker_#{System.unique_integer([:positive])}"
      start_supervised!({Resiliency.Hedged.Tracker, name: name, buffer_size: 10})

      for i <- 1..1000 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: i,
          hedged?: false,
          hedge_won?: false
        })
      end

      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.total_requests == 1000
      # Percentiles reflect recent values (991..1000)
      assert stats.p50 >= 991
    end
  end
end
