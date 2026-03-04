defmodule Resiliency.RateLimiterTest do
  use ExUnit.Case, async: true
  doctest Resiliency.RateLimiter

  # --- Helpers ---

  defp tab_for(name) do
    {tab, _, _, _, _, _} = :persistent_term.get({Resiliency.RateLimiter.Server, :config, name})
    tab
  end

  defp start_rl!(opts \\ []) do
    name = :"rl_#{System.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put_new(:rate, 100.0)
      |> Keyword.put_new(:burst_size, 10)
      |> Keyword.put(:name, name)

    start_supervised!({Resiliency.RateLimiter, opts})
    name
  end

  # --- Basic allow ---

  describe "call/2 basic allow" do
    test "returns {:ok, result} wrapping a bare value" do
      rl = start_rl!()
      assert {:ok, 42} = Resiliency.RateLimiter.call(rl, fn -> 42 end)
    end

    test "passes {:ok, result} through unchanged (normalize does not double-wrap)" do
      rl = start_rl!()
      assert {:ok, "data"} = Resiliency.RateLimiter.call(rl, fn -> {:ok, "data"} end)
    end

    test "passes {:error, reason} through unchanged" do
      rl = start_rl!()

      assert {:error, :not_found} =
               Resiliency.RateLimiter.call(rl, fn -> {:error, :not_found} end)
    end

    test "function runs in caller's process" do
      rl = start_rl!()
      caller = self()
      {:ok, pid} = Resiliency.RateLimiter.call(rl, fn -> self() end)
      assert pid == caller
    end
  end

  # --- Error handling ---

  describe "call/2 error handling" do
    test "raise returns {:error, {exception, stacktrace}}" do
      rl = start_rl!()

      assert {:error, {%RuntimeError{message: "boom"}, stacktrace}} =
               Resiliency.RateLimiter.call(rl, fn -> raise "boom" end)

      assert is_list(stacktrace)
    end

    test "exit returns {:error, reason}" do
      rl = start_rl!()
      assert {:error, :oops} = Resiliency.RateLimiter.call(rl, fn -> exit(:oops) end)
    end

    test "throw returns {:error, {:nocatch, value}}" do
      rl = start_rl!()

      assert {:error, {:nocatch, :thrown}} =
               Resiliency.RateLimiter.call(rl, fn -> throw(:thrown) end)
    end
  end

  # --- Rate limiting ---

  describe "rate limiting" do
    test "returns {:error, {:rate_limited, ms}} with a positive integer retry_after" do
      # rate: 1.0 token/s, burst: 1 — drain then reject
      rl = start_rl!(rate: 1.0, burst_size: 1)
      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      assert {:error, {:rate_limited, ms}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      assert is_integer(ms)
      assert ms >= 1
    end

    test "retry_after formula: full drain at rate 1.0 gives ~1000ms hint" do
      rl = start_rl!(rate: 1.0, burst_size: 1)
      {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      {:error, {:rate_limited, ms}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      # deficit ≈ 1.0 token at rate 1.0/s → ~1000ms; allow 200ms for elapsed time between calls
      assert ms >= 800
      assert ms <= 1000
    end
  end

  # --- Burst ---

  describe "burst" do
    test "exactly burst_size calls succeed before rejection" do
      burst = 5
      # rate near zero so no refill happens between calls
      rl = start_rl!(rate: 0.001, burst_size: burst)

      for _ <- 1..burst do
        assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      end

      assert {:error, {:rate_limited, _}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
    end
  end

  # --- Reset ---

  describe "reset/1" do
    test "refills the bucket so calls are accepted again" do
      rl = start_rl!(rate: 0.001, burst_size: 2)

      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      assert {:error, {:rate_limited, _}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      assert :ok = Resiliency.RateLimiter.reset(rl)

      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
    end
  end

  # --- Weight ---

  describe "weight option" do
    test "weight: 3 consumes 3 tokens per call" do
      # burst 9, weight 3 → exactly 3 calls before rejection
      rl = start_rl!(rate: 0.001, burst_size: 9)

      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end, weight: 3)
      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end, weight: 3)
      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end, weight: 3)

      assert {:error, {:rate_limited, _}} =
               Resiliency.RateLimiter.call(rl, fn -> :ok end, weight: 3)
    end

    test "weight > burst_size always rejects" do
      rl = start_rl!(rate: 0.001, burst_size: 3)

      assert {:error, {:rate_limited, _}} =
               Resiliency.RateLimiter.call(rl, fn -> :ok end, weight: 4)
    end

    test "invalid weight raises ArgumentError" do
      rl = start_rl!()

      assert_raise ArgumentError, ~r/weight/, fn ->
        Resiliency.RateLimiter.call(rl, fn -> :ok end, weight: 0)
      end
    end
  end

  # --- on_reject callback ---

  describe "on_reject callback" do
    test "fires when rejected, not when accepted" do
      test_pid = self()
      cb = fn name -> send(test_pid, {:rejected, name}) end
      rl = start_rl!(rate: 0.001, burst_size: 1, on_reject: cb)

      # First call succeeds — no callback
      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      refute_received {:rejected, _}

      # Second call is rejected — callback fires
      assert {:error, {:rate_limited, _}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      assert_received {:rejected, ^rl}
    end

    test "callback crash does not kill the rate limiter" do
      cb = fn _name -> raise "callback boom" end
      rl = start_rl!(rate: 0.001, burst_size: 1, on_reject: cb)

      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      # This triggers the crashing callback
      assert {:error, {:rate_limited, _}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      # Rate limiter is still alive
      assert %{burst_size: 1} = Resiliency.RateLimiter.get_stats(rl)
    end
  end

  # --- get_stats ---

  describe "get_stats/1" do
    test "returns map with tokens, rate, burst_size" do
      rl = start_rl!(rate: 50.0, burst_size: 8)
      stats = Resiliency.RateLimiter.get_stats(rl)

      assert %{tokens: _, rate: 50.0, burst_size: 8} = stats
      assert is_float(stats.tokens)
    end

    test "tokens decrease after calls" do
      rl = start_rl!(rate: 0.001, burst_size: 10)

      before = Resiliency.RateLimiter.get_stats(rl).tokens
      Resiliency.RateLimiter.call(rl, fn -> :ok end)
      after_call = Resiliency.RateLimiter.get_stats(rl).tokens

      assert after_call < before
    end

    test "tokens are full after reset" do
      rl = start_rl!(rate: 0.001, burst_size: 5)

      Resiliency.RateLimiter.call(rl, fn -> :ok end)
      Resiliency.RateLimiter.call(rl, fn -> :ok end)

      Resiliency.RateLimiter.reset(rl)
      stats = Resiliency.RateLimiter.get_stats(rl)

      assert stats.tokens >= 4.9
    end

    test "get_stats does not update last_refill_at in ETS" do
      rl = start_rl!(rate: 0.001, burst_size: 5)
      [{:bucket, _tokens, ts_before}] = :ets.lookup(tab_for(rl), :bucket)
      Resiliency.RateLimiter.get_stats(rl)
      [{:bucket, _tokens2, ts_after}] = :ets.lookup(tab_for(rl), :bucket)
      assert ts_before == ts_after
    end
  end

  # --- Concurrent callers ---

  describe "concurrent callers" do
    test "exactly burst_size grants with 50 concurrent callers" do
      burst = 50
      rl = start_rl!(rate: 0.001, burst_size: burst)

      results =
        1..burst
        |> Task.async_stream(fn _ -> Resiliency.RateLimiter.call(rl, fn -> :ok end) end,
          max_concurrency: burst
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # One extra call to confirm the bucket is truly empty
      assert {:error, {:rate_limited, _}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      grants = Enum.count(results, &match?({:ok, _}, &1))
      assert grants == burst
    end

    test "exactly burst_size grants with 200 concurrent callers" do
      burst = 200
      rl = start_rl!(rate: 0.001, burst_size: burst)

      results =
        1..burst
        |> Task.async_stream(fn _ -> Resiliency.RateLimiter.call(rl, fn -> :ok end) end,
          max_concurrency: burst
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert {:error, {:rate_limited, _}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      grants = Enum.count(results, &match?({:ok, _}, &1))
      assert grants == burst
    end
  end

  # --- Duplicate start ---

  describe "duplicate start" do
    test "start_link with same name returns {:error, {:already_started, _}}" do
      name = :"rl_dup_#{System.unique_integer([:positive])}"
      opts = [name: name, rate: 1.0, burst_size: 1]

      {:ok, _pid} = Resiliency.RateLimiter.start_link(opts)
      assert {:error, {:already_started, _}} = Resiliency.RateLimiter.start_link(opts)
    end
  end

  # --- Unknown name ---

  describe "unknown name" do
    test "call with unknown name raises ArgumentError" do
      assert_raise ArgumentError, ~r/no rate limiter registered under name/, fn ->
        Resiliency.RateLimiter.call(:no_such_rate_limiter_xyz, fn -> :ok end)
      end
    end
  end

  # --- child_spec ---

  describe "child_spec/1" do
    test "id is {Resiliency.RateLimiter, name}" do
      spec = Resiliency.RateLimiter.child_spec(name: :my_rl, rate: 1.0, burst_size: 1)
      assert spec.id == {Resiliency.RateLimiter, :my_rl}
    end

    test "type is :worker" do
      spec = Resiliency.RateLimiter.child_spec(name: :my_rl2, rate: 1.0, burst_size: 1)
      assert spec.type == :worker
    end
  end
end
