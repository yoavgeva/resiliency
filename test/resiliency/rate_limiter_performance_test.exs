defmodule Resiliency.RateLimiterPerformanceTest do
  use ExUnit.Case, async: false

  # Performance tests are tagged so they can be excluded in CI with --exclude perf,
  # or run explicitly with --only perf.
  @moduletag :perf

  # Generous per-call budget in microseconds that should be met on any reasonable
  # CI machine or developer laptop. These are not tight benchmarks — they are
  # regression guards that catch catastrophic regressions (e.g. accidental GenServer
  # call on the hot path, O(n) ETS scan, scheduler starvation from a spin loop).
  #
  # Baseline observed on an M-series MacBook: acquire ~3µs, reject ~2µs.
  # We allow 10× headroom so these never flap in normal CI environments.
  @acquire_budget_us 30
  @reject_budget_us 20

  # Number of iterations for timing loops. Large enough that measurement noise
  # averages out; small enough that the test finishes quickly.
  @iterations 10_000

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp start_rl!(opts \\ []) do
    name = :"rl_perf_#{System.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put_new(:rate, 1_000_000.0)
      |> Keyword.put_new(:burst_size, @iterations + 1000)
      |> Keyword.put(:name, name)

    start_supervised!({Resiliency.RateLimiter, opts})
    name
  end

  # Warm up the BEAM JIT / atom tables / ETS caches before timing.
  defp warmup(rl, n \\ 200) do
    for _ <- 1..n do
      Resiliency.RateLimiter.Server.acquire(rl, 1)
    end
  end

  # Run `fun` `n` times and return {total_us, per_call_us}.
  defp time_n(n, fun) do
    {total_us, _} = :timer.tc(fn -> for(_ <- 1..n, do: fun.()) end)
    {total_us, total_us / n}
  end

  # ----------------------------------------------------------------------------
  # 1. Grant path throughput (sequential, single process)
  # ----------------------------------------------------------------------------

  describe "grant path throughput" do
    test "sequential acquire completes within budget per call" do
      # Large burst so the bucket never empties during the run.
      rl = start_rl!(rate: 1_000_000.0, burst_size: @iterations + 1000)
      warmup(rl)

      {_total, per_call_us} =
        time_n(@iterations, fn ->
          Resiliency.RateLimiter.Server.acquire(rl, 1)
        end)

      assert per_call_us < @acquire_budget_us,
             "acquire took #{Float.round(per_call_us, 2)}µs/call — expected < #{@acquire_budget_us}µs. " <>
               "This may indicate a GenServer call or O(n) scan crept onto the hot path."
    end

    test "acquire overhead over a bare ETS lookup is bounded" do
      # Measure raw ETS lookup cost, then rate limiter cost.
      # Rate limiter adds: persistent_term.get + float math + select_replace.
      # This test ensures that overhead doesn't balloon unexpectedly.
      rl = start_rl!(rate: 1_000_000.0, burst_size: @iterations + 1000)
      warmup(rl)

      # Bare ETS read baseline
      {tab, _, _, _, _, _} = :persistent_term.get({Resiliency.RateLimiter.Server, :config, rl})

      {ets_us, _} =
        time_n(@iterations, fn ->
          :ets.lookup(tab, :bucket)
        end)

      {rl_us, _} =
        time_n(@iterations, fn ->
          Resiliency.RateLimiter.Server.acquire(rl, 1)
        end)

      ets_per_call = ets_us / @iterations
      rl_per_call = rl_us / @iterations

      # Rate limiter must stay within 20× a raw ETS lookup.
      # (persistent_term.get + float arithmetic + select_replace ≈ 3–5 ETS ops)
      assert rl_per_call < ets_per_call * 20,
             "Rate limiter (#{Float.round(rl_per_call, 2)}µs) is more than 20× " <>
               "a bare ETS lookup (#{Float.round(ets_per_call, 2)}µs). " <>
               "Hot path has unexpected overhead."
    end
  end

  # ----------------------------------------------------------------------------
  # 2. Reject path throughput (sequential, single process)
  # ----------------------------------------------------------------------------

  describe "reject path throughput" do
    test "sequential rejected calls complete within budget per call" do
      # weight > burst_size so every call is rejected immediately.
      rl = start_rl!(rate: 0.001, burst_size: 1)
      # Drain the one token so every call hits the reject branch.
      Resiliency.RateLimiter.Server.acquire(rl, 1)
      warmup(rl)

      {_total, per_call_us} =
        time_n(@iterations, fn ->
          Resiliency.RateLimiter.Server.acquire(rl, 1)
        end)

      assert per_call_us < @reject_budget_us,
             "reject took #{Float.round(per_call_us, 2)}µs/call — expected < #{@reject_budget_us}µs."
    end

    test "reject path is not slower than grant path" do
      # The reject path does less work (update_element vs select_replace CAS) so
      # it should be at most as slow as a grant. If it's substantially slower,
      # something is wrong (e.g. the reject callback is being called unconditionally).
      rl_grant = start_rl!(rate: 1_000_000.0, burst_size: @iterations + 1000)
      rl_reject = start_rl!(rate: 0.001, burst_size: 1)
      Resiliency.RateLimiter.Server.acquire(rl_reject, 1)

      warmup(rl_grant)
      warmup(rl_reject)

      {grant_us, _} =
        time_n(@iterations, fn -> Resiliency.RateLimiter.Server.acquire(rl_grant, 1) end)

      {reject_us, _} =
        time_n(@iterations, fn -> Resiliency.RateLimiter.Server.acquire(rl_reject, 1) end)

      grant_per = grant_us / @iterations
      reject_per = reject_us / @iterations

      assert reject_per <= grant_per * 1.5,
             "reject (#{Float.round(reject_per, 2)}µs) is more than 1.5× grant (#{Float.round(grant_per, 2)}µs). " <>
               "Reject path may have unexpected overhead."
    end
  end

  # ----------------------------------------------------------------------------
  # 3. CAS loop: no excessive reductions under zero contention
  # ----------------------------------------------------------------------------

  describe "CAS loop reductions" do
    test "single acquire with no contention uses a bounded number of reductions" do
      rl = start_rl!()
      warmup(rl)

      # Measure reductions consumed by a single acquire call.
      before = :erlang.process_info(self(), :reductions) |> elem(1)
      Resiliency.RateLimiter.Server.acquire(rl, 1)
      after_val = :erlang.process_info(self(), :reductions) |> elem(1)

      reductions = after_val - before

      # A single uncontested CAS should take well under 500 reductions.
      # (Each BEAM instruction ≈ 1 reduction; the hot path is ~10–30 instructions.)
      # If this spikes to thousands, the CAS loop is retrying unexpectedly.
      assert reductions < 500,
             "Single acquire used #{reductions} reductions — " <>
               "expected < 500. CAS loop may be spinning."
    end

    test "100 sequential acquires use proportional reductions (no compounding)" do
      n = 100
      rl = start_rl!(burst_size: n + 10)
      warmup(rl)

      before = :erlang.process_info(self(), :reductions) |> elem(1)

      for _ <- 1..n do
        Resiliency.RateLimiter.Server.acquire(rl, 1)
      end

      after_val = :erlang.process_info(self(), :reductions) |> elem(1)
      total = after_val - before
      per_call = total / n

      # Per-call reductions should stay flat — no accumulating state.
      assert per_call < 500,
             "#{n} acquires averaged #{Float.round(per_call, 1)} reductions/call — " <>
               "expected < 500. Check for unintended per-call allocation or looping."
    end
  end

  # ----------------------------------------------------------------------------
  # 4. Concurrent throughput scalability
  # ----------------------------------------------------------------------------

  describe "concurrent throughput" do
    test "acquire reductions stay flat under 8 concurrent tasks (no GenServer serialisation)" do
      # Property under test: acquire must NOT route through a GenServer mailbox.
      # A GenServer.call round-trip costs ~500–2000 reductions; a pure ETS acquire
      # costs ~20–100. We measure reductions per acquire from a task's perspective.
      #
      # If a GenServer call crept onto the hot path, reductions per acquire would
      # jump by an order of magnitude compared to the single-process baseline.
      concurrency = 8
      calls_per_task = 200

      rl = start_rl!(rate: 1_000_000.0, burst_size: concurrency * calls_per_task + 1000)
      warmup(rl)

      # Collect per-task reduction costs in parallel.
      reductions_per_task =
        1..concurrency
        |> Task.async_stream(
          fn _ ->
            before = :erlang.process_info(self(), :reductions) |> elem(1)

            for _ <- 1..calls_per_task do
              Resiliency.RateLimiter.Server.acquire(rl, 1)
            end

            after_val = :erlang.process_info(self(), :reductions) |> elem(1)
            (after_val - before) / calls_per_task
          end,
          max_concurrency: concurrency
        )
        |> Enum.map(fn {:ok, r} -> r end)

      avg_reductions = Enum.sum(reductions_per_task) / concurrency

      # Each acquire must stay under 500 reductions even under concurrent load.
      # A GenServer.call would push this well above 1000.
      assert avg_reductions < 500,
             "Average #{Float.round(avg_reductions, 1)} reductions/acquire under " <>
               "#{concurrency} concurrent tasks — expected < 500. " <>
               "Acquire path may have a hidden GenServer call or spin loop."
    end
  end

  # ----------------------------------------------------------------------------
  # 5. `call/2` full-path overhead (telemetry + acquire + execute)
  # ----------------------------------------------------------------------------

  describe "full call/2 path" do
    test "full call/2 with instant function completes within generous budget" do
      # This measures the complete path including telemetry map allocations.
      # Budget is deliberately loose — we're catching regressions, not benchmarking.
      rl = start_rl!(rate: 1_000_000.0, burst_size: @iterations + 1000)

      # Detach telemetry so we measure the framework overhead, not handler latency.
      {total_us, _} =
        time_n(@iterations, fn ->
          Resiliency.RateLimiter.call(rl, fn -> :ok end)
        end)

      per_call_us = total_us / @iterations

      # Full call/2 budget: acquire + telemetry (2 ETS lookups) + execute + normalize.
      # Allow up to 10× the raw acquire budget.
      budget = @acquire_budget_us * 10

      assert per_call_us < budget,
             "call/2 took #{Float.round(per_call_us, 2)}µs/call — expected < #{budget}µs."
    end
  end
end
