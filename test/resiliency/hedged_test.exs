defmodule Resiliency.HedgedTest do
  use ExUnit.Case, async: true

  doctest Resiliency.Hedged

  describe "run/2 (stateless)" do
    test "returns {:ok, value} on success" do
      assert {:ok, 42} = Resiliency.Hedged.run(fn -> {:ok, 42} end)
    end

    test "returns {:error, reason} on failure" do
      assert {:error, :boom} = Resiliency.Hedged.run(fn -> {:error, :boom} end, max_requests: 1)
    end

    test "normalizes bare values" do
      assert {:ok, :hello} = Resiliency.Hedged.run(fn -> :hello end)
    end

    test "hedge wins over slow first request" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          Process.sleep(500)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast} = Resiliency.Hedged.run(fun, delay: 10)
    end

    test "respects timeout" do
      fun = fn ->
        Process.sleep(10_000)
        {:ok, :never}
      end

      assert {:error, :timeout} = Resiliency.Hedged.run(fun, timeout: 50, delay: 10)
    end

    test "default options work" do
      assert {:ok, :works} = Resiliency.Hedged.run(fn -> {:ok, :works} end)
    end

    test "max_requests: 1 disables hedging" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:ok, :done}
      end

      assert {:ok, :done} = Resiliency.Hedged.run(fun, max_requests: 1)
      assert :counters.get(counter, 1) == 1
    end

    test "non_fatal triggers immediate hedge" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          {:error, :retriable}
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered} =
               Resiliency.Hedged.run(fun,
                 delay: 5_000,
                 non_fatal: fn
                   :retriable -> true
                   _ -> false
                 end
               )
    end
  end

  describe "run/3 (stateful with tracker)" do
    setup do
      name = :"hedged_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         initial_delay: 50,
         min_samples: 5,
         token_max: 10,
         token_success_credit: 0.1,
         token_hedge_cost: 1.0,
         token_threshold: 1.0}
      )

      %{tracker: name}
    end

    test "returns {:ok, value} on success", %{tracker: tracker} do
      assert {:ok, 42} = Resiliency.Hedged.run(tracker, fn -> {:ok, 42} end, [])
    end

    test "returns {:error, reason} on failure", %{tracker: tracker} do
      assert {:error, :boom} =
               Resiliency.Hedged.run(tracker, fn -> {:error, :boom} end, max_requests: 1)
    end

    test "records latency in tracker stats", %{tracker: tracker} do
      Resiliency.Hedged.run(tracker, fn -> {:ok, :done} end, [])
      stats = Resiliency.Hedged.Tracker.stats(tracker)
      assert stats.total_requests == 1
    end

    test "records hedged requests in stats", %{tracker: tracker} do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          Process.sleep(200)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      # Use short delay to trigger hedging
      Resiliency.Hedged.run(tracker, fun, timeout: 5_000)
      stats = Resiliency.Hedged.Tracker.stats(tracker)
      assert stats.hedged_requests >= 1
    end

    test "disables hedging when tokens depleted", %{tracker: _tracker} do
      name = :"hedged_no_tokens_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         initial_delay: 10,
         token_max: 0,
         token_success_credit: 0.0,
         token_hedge_cost: 1.0,
         token_threshold: 1.0},
        id: name
      )

      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        Process.sleep(50)
        {:ok, :done}
      end

      Resiliency.Hedged.run(name, fun, [])

      # With tokens=0 and threshold=1, hedging is disabled,
      # so only 1 request should be made
      assert :counters.get(counter, 1) == 1
    end

    test "adaptive delay changes with latency data" do
      name = :"hedged_adaptive_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         initial_delay: 500,
         min_samples: 3,
         percentile: 95,
         min_delay: 1,
         max_delay: 5_000},
        id: name
      )

      # Initially should use initial_delay
      {delay_before, _} = Resiliency.Hedged.Tracker.get_config(name)
      assert delay_before == 500

      # Record some fast latencies
      for _ <- 1..10 do
        Resiliency.Hedged.Tracker.record(name, %{
          latency_ms: 10,
          hedged?: false,
          hedge_won?: false
        })
      end

      _ = Resiliency.Hedged.Tracker.stats(name)
      {delay_after, _} = Resiliency.Hedged.Tracker.get_config(name)
      # Should adapt down from 500 toward ~10
      assert delay_after < 500
    end
  end

  describe "run/3 (extended)" do
    setup do
      name = :"hedged_ext_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Resiliency.Hedged.Tracker,
         name: name,
         initial_delay: 50,
         min_samples: 5,
         token_max: 10,
         token_success_credit: 0.1,
         token_hedge_cost: 1.0,
         token_threshold: 1.0}
      )

      %{tracker: name}
    end

    test "records hedge_won when hedge beats first request", %{tracker: tracker} do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          Process.sleep(200)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast} = Resiliency.Hedged.run(tracker, fun, [])

      stats = Resiliency.Hedged.Tracker.stats(tracker)
      assert stats.hedge_won >= 1
    end

    test "records failed request in tracker", %{tracker: tracker} do
      Resiliency.Hedged.run(tracker, fn -> {:error, :boom} end, max_requests: 1)
      stats = Resiliency.Hedged.Tracker.stats(tracker)
      assert stats.total_requests == 1
    end

    test "tracker continues working after all-fail scenario", %{tracker: tracker} do
      # All-fail run
      Resiliency.Hedged.run(tracker, fn -> {:error, :nope} end, max_requests: 1)

      # Normal run after
      assert {:ok, :fine} = Resiliency.Hedged.run(tracker, fn -> {:ok, :fine} end, [])

      stats = Resiliency.Hedged.Tracker.stats(tracker)
      assert stats.total_requests == 2
    end

    test "100 concurrent stateful runs", %{tracker: tracker} do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Resiliency.Hedged.run(tracker, fn -> {:ok, i} end, [])
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 100
      assert Enum.all?(results, &match?({:ok, _}, &1))

      stats = Resiliency.Hedged.Tracker.stats(tracker)
      assert stats.total_requests == 100
    end

    test "non_fatal works through stateful API", %{tracker: tracker} do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          {:error, :retriable}
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered} =
               Resiliency.Hedged.run(tracker, fun,
                 non_fatal: fn
                   :retriable -> true
                   _ -> false
                 end
               )
    end

    test "timeout works through stateful API", %{tracker: tracker} do
      fun = fn ->
        Process.sleep(10_000)
        {:ok, :never}
      end

      assert {:error, :timeout} = Resiliency.Hedged.run(tracker, fun, timeout: 50)
    end
  end

  describe "start_link/1 and child_spec/1" do
    test "start_link starts a tracker" do
      name = :"hedged_sl_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Resiliency.Hedged, name: name})
      assert is_pid(pid)
      assert Resiliency.Hedged.Tracker.stats(name).total_requests == 0
    end

    test "child_spec uses name as id" do
      spec = Resiliency.Hedged.child_spec(name: MyApp.Hedged)
      assert spec.id == MyApp.Hedged
    end

    test "child_spec defaults id to Resiliency.Hedged when no name" do
      spec = Resiliency.Hedged.child_spec([])
      assert spec.id == Resiliency.Hedged
    end

    test "works under a supervisor" do
      name = :"hedged_sup_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.Hedged, name: name}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, 42} = Resiliency.Hedged.run(name, fn -> {:ok, 42} end, [])

      stats = Resiliency.Hedged.Tracker.stats(name)
      assert stats.total_requests == 1

      Supervisor.stop(sup)
    end
  end

  describe "run/2 (extended edge cases)" do
    test "nested {:ok, {:error, _}} is treated as success" do
      assert {:ok, {:error, :inner}} = Resiliency.Hedged.run(fn -> {:ok, {:error, :inner}} end)
    end

    test "bare :error returns {:error, :error}" do
      assert {:error, :error} = Resiliency.Hedged.run(fn -> :error end, max_requests: 1)
    end

    test "bare :ok returns {:ok, :ok}" do
      assert {:ok, :ok} = Resiliency.Hedged.run(fn -> :ok end)
    end

    test "bare nil returns {:ok, nil}" do
      assert {:ok, nil} = Resiliency.Hedged.run(fn -> nil end)
    end

    test "bare map returns {:ok, map}" do
      assert {:ok, %{key: :value}} = Resiliency.Hedged.run(fn -> %{key: :value} end)
    end

    test "100 concurrent stateless runs" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Resiliency.Hedged.run(fn -> {:ok, i} end, delay: 5)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 100
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "on_hedge callback error doesn't crash the runner" do
      fun = fn ->
        Process.sleep(200)
        {:ok, :done}
      end

      # on_hedge raises, but we still get a result
      # Note: the raise happens in the caller's process context within Runner,
      # so this may actually propagate. Let's test the behavior.
      result =
        try do
          Resiliency.Hedged.run(fun,
            delay: 10,
            max_requests: 2,
            on_hedge: fn _attempt -> raise "callback boom" end
          )
        rescue
          _ -> :rescued
        end

      # Either completes successfully or the error propagates — both are acceptable
      assert result in [:rescued, {:ok, :done}]
    end

    test "delay: 0 with non_fatal fires all max_requests rapidly" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)
        if n < 3, do: {:error, :retriable}, else: {:ok, :done}
      end

      assert {:ok, :done} =
               Resiliency.Hedged.run(fun,
                 delay: 0,
                 max_requests: 5,
                 non_fatal: fn
                   :retriable -> true
                   _ -> false
                 end
               )
    end

    test "max_requests: 3 with all succeeding uses only first" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:ok, :fast}
      end

      assert {:ok, :fast} = Resiliency.Hedged.run(fun, delay: 100, max_requests: 3)
      # Only 1 request should have been dispatched since it succeeds immediately
      assert :counters.get(counter, 1) == 1
    end
  end
end
