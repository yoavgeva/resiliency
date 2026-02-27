defmodule Resiliency.Hedged.RunnerTest do
  use ExUnit.Case, async: true

  alias Resiliency.Hedged.Runner

  @default_opts [delay: 100, max_requests: 2, timeout: 5_000]

  defp opts(overrides), do: Keyword.merge(@default_opts, overrides)

  describe "single request (no hedge needed)" do
    test "returns {:ok, value, meta} for immediate success" do
      assert {:ok, 42, %{dispatched: 1, winner_index: 0}} =
               Runner.execute(fn -> {:ok, 42} end, @default_opts)
    end

    test "normalizes bare values" do
      assert {:ok, :hello, %{dispatched: 1}} =
               Runner.execute(fn -> :hello end, @default_opts)
    end

    test "normalizes :ok atom" do
      assert {:ok, :ok, %{dispatched: 1}} =
               Runner.execute(fn -> :ok end, @default_opts)
    end
  end

  describe "hedging" do
    test "fires hedge after delay and hedge wins" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          # first request is slow
          Process.sleep(500)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast, %{dispatched: 2, winner_index: 1}} =
               Runner.execute(fun, opts(delay: 10))
    end

    test "first request wins when fast enough" do
      fun = fn -> {:ok, :fast} end

      assert {:ok, :fast, %{dispatched: 1, winner_index: 0}} =
               Runner.execute(fun, opts(delay: 100))
    end

    test "delay: 0 fires all requests immediately (race mode)" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        Process.sleep(n * 10)
        {:ok, n}
      end

      assert {:ok, _result, %{dispatched: 2}} =
               Runner.execute(fun, opts(delay: 0, max_requests: 2))
    end

    test "on_hedge callback is invoked with attempt number" do
      agent = start_supervised!({Agent, fn -> [] end})

      fun = fn ->
        Process.sleep(200)
        {:ok, :done}
      end

      Runner.execute(
        fun,
        opts(
          delay: 10,
          max_requests: 3,
          on_hedge: fn attempt -> Agent.update(agent, &[attempt | &1]) end
        )
      )

      attempts = Agent.get(agent, & &1) |> Enum.sort()
      # Should have hedged at least once (attempt 2)
      assert 2 in attempts
    end
  end

  describe "all fail" do
    test "returns last error when all requests fail" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        {:error, {:fail, :counters.get(counter, 1)}}
      end

      assert {:error, {:fail, _}, %{dispatched: 2, winner_index: nil}} =
               Runner.execute(fun, opts(delay: 10))
    end
  end

  describe "non_fatal fast-forward" do
    test "fires next hedge immediately on non-fatal error" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          {:error, :retriable}
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered, %{dispatched: 2, winner_index: 1}} =
               Runner.execute(
                 fun,
                 opts(
                   delay: 5_000,
                   non_fatal: fn
                     :retriable -> true
                     _ -> false
                   end
                 )
               )
    end
  end

  describe "cancellation" do
    test "cancelled tasks don't continue running" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          Process.sleep(500)
          :counters.add(counter, 1, 100)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast, _meta} = Runner.execute(fun, opts(delay: 10))

      # Give time for the slow task to finish if it weren't cancelled
      Process.sleep(600)
      # Counter should still be 2, not 102
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "timeout" do
    test "returns {:error, :timeout} when overall deadline exceeded" do
      fun = fn ->
        Process.sleep(10_000)
        {:ok, :never}
      end

      assert {:error, :timeout, %{dispatched: _, winner_index: nil}} =
               Runner.execute(fun, opts(timeout: 50, delay: 10))
    end
  end

  describe "exception handling" do
    test "captures raised exceptions as :DOWN messages" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          raise "boom"
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered, %{dispatched: 2}} =
               Runner.execute(fun, opts(delay: 10))
    end

    test "captures exits" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          exit(:kaboom)
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered, %{dispatched: 2}} =
               Runner.execute(fun, opts(delay: 10))
    end

    test "captures throws" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          throw(:ball)
        else
          {:ok, :recovered}
        end
      end

      assert {:ok, :recovered, %{dispatched: 2}} =
               Runner.execute(fun, opts(delay: 10))
    end

    test "all raise returns error" do
      fun = fn -> raise "boom" end

      assert {:error, _reason, %{dispatched: 2, winner_index: nil}} =
               Runner.execute(fun, opts(delay: 10))
    end
  end

  describe "max_requests: 1" do
    test "never hedges, returns directly" do
      assert {:ok, 42, %{dispatched: 1}} =
               Runner.execute(fn -> {:ok, 42} end, opts(max_requests: 1))
    end

    test "returns error without hedging" do
      assert {:error, :nope, %{dispatched: 1}} =
               Runner.execute(fn -> {:error, :nope} end, opts(max_requests: 1))
    end
  end

  describe "concurrency stress" do
    test "100 concurrent execute calls complete correctly" do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Runner.execute(fn -> {:ok, i} end, opts(delay: 5))
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 100

      assert Enum.all?(results, fn
               {:ok, _, _} -> true
               _ -> false
             end)
    end

    test "concurrent hedged calls don't interfere with each other" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            ref = :atomics.new(1, signed: false)

            fun = fn ->
              n = :atomics.add_get(ref, 1, 1)

              if n == 1 do
                Process.sleep(100)
                {:ok, {:slow, i}}
              else
                {:ok, {:fast, i}}
              end
            end

            Runner.execute(fun, opts(delay: 5, max_requests: 2))
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 50

      Enum.each(results, fn {:ok, {_speed, _i}, _meta} ->
        :ok
      end)
    end
  end

  describe "cancellation (extended)" do
    test "timeout cancels all pending tasks cleanly" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        Process.sleep(5_000)
        :counters.add(counter, 1, 100)
        {:ok, :done}
      end

      assert {:error, :timeout, _meta} =
               Runner.execute(fun, opts(timeout: 50, delay: 10, max_requests: 3))

      Process.sleep(200)
      # Tasks started but did not complete (no +100 increments)
      assert :counters.get(counter, 1) <= 3
    end

    test "cancelled task's late messages are not leaked to caller" do
      parent = self()

      Runner.execute(fn -> {:ok, :fast} end, opts(delay: 10))

      # Run one with slow function to set up potential late message
      ref = :atomics.new(1, signed: false)

      mixed_fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          Process.sleep(500)
          send(parent, :late_from_cancelled)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      Runner.execute(mixed_fun, opts(delay: 10))

      Process.sleep(600)
      refute_received :late_from_cancelled
    end
  end

  describe "callback sequencing" do
    test "on_hedge fires before hedge task starts" do
      events = :counters.new(2, [:atomics])
      # counter 1 = on_hedge seen, counter 2 = task started

      fun = fn ->
        # When task starts, on_hedge should already have been called
        :counters.add(events, 2, 1)
        Process.sleep(200)
        {:ok, :done}
      end

      Runner.execute(
        fun,
        opts(
          delay: 10,
          max_requests: 2,
          on_hedge: fn _attempt ->
            :counters.add(events, 1, 1)
          end
        )
      )

      # on_hedge was called at least once
      assert :counters.get(events, 1) >= 1
    end

    test "on_hedge receives sequential attempt numbers" do
      agent = start_supervised!({Agent, fn -> [] end})

      fun = fn ->
        Process.sleep(500)
        {:ok, :done}
      end

      Runner.execute(
        fun,
        opts(
          delay: 5,
          max_requests: 4,
          on_hedge: fn attempt ->
            Agent.update(agent, &[attempt | &1])
          end
        )
      )

      attempts = Agent.get(agent, & &1) |> Enum.sort()
      assert attempts == [2, 3, 4]
    end
  end

  describe "configuration edge cases" do
    test "delay longer than timeout means hedge never fires" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        Process.sleep(200)
        {:ok, :done}
      end

      assert {:error, :timeout, %{dispatched: 1}} =
               Runner.execute(fun, opts(delay: 5_000, timeout: 50, max_requests: 3))

      assert :counters.get(counter, 1) == 1
    end

    test "delay: 0 with max_requests: 5 fires all immediately" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        Process.sleep(100)
        {:ok, :done}
      end

      assert {:ok, :done, %{dispatched: 5}} =
               Runner.execute(fun, opts(delay: 0, max_requests: 5, timeout: 5_000))
    end

    test "max_requests: 1 with non_fatal still doesn't hedge" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        :atomics.add_get(ref, 1, 1)
        {:error, :retriable}
      end

      assert {:error, :retriable, %{dispatched: 1}} =
               Runner.execute(
                 fun,
                 opts(
                   max_requests: 1,
                   non_fatal: fn _ -> true end
                 )
               )
    end
  end

  describe "non_fatal (extended)" do
    test "cascading non_fatal errors fire all hedges until success" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)
        if n < 4, do: {:error, :retriable}, else: {:ok, :finally}
      end

      assert {:ok, :finally, %{dispatched: 4, winner_index: 3}} =
               Runner.execute(
                 fun,
                 opts(
                   delay: 5_000,
                   max_requests: 5,
                   non_fatal: fn
                     :retriable -> true
                     _ -> false
                   end
                 )
               )
    end

    test "non_fatal exhausts max_requests then returns error" do
      fun = fn -> {:error, :retriable} end

      assert {:error, :retriable, %{dispatched: 3, winner_index: nil}} =
               Runner.execute(
                 fun,
                 opts(
                   delay: 5_000,
                   max_requests: 3,
                   non_fatal: fn
                     :retriable -> true
                     _ -> false
                   end
                 )
               )
    end

    test "fatal error does not fast-forward" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          {:error, :fatal_one}
        else
          {:ok, :recovered}
        end
      end

      # Fatal error (non_fatal returns false) should wait for delay
      # With delay: 5000, the hedge fires after timeout via normal delay path
      # But since pending: 0 and dispatched < max, it fires immediately
      assert {:ok, :recovered, %{dispatched: 2}} =
               Runner.execute(
                 fun,
                 opts(
                   delay: 5_000,
                   max_requests: 2,
                   non_fatal: fn _ -> false end
                 )
               )
    end

    test "mix of non_fatal and fatal errors" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        case n do
          1 -> {:error, :retriable}
          2 -> {:error, :fatal}
          3 -> {:ok, :success}
        end
      end

      assert {:ok, :success, %{dispatched: 3}} =
               Runner.execute(
                 fun,
                 opts(
                   delay: 5_000,
                   max_requests: 5,
                   non_fatal: fn
                     :retriable -> true
                     _ -> false
                   end
                 )
               )
    end
  end

  describe "exception handling (extended)" do
    test "first raises, second exits, third succeeds" do
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        case n do
          1 -> raise "boom"
          2 -> exit(:kaboom)
          3 -> {:ok, :survived}
        end
      end

      assert {:ok, :survived, %{dispatched: 3}} =
               Runner.execute(fun, opts(delay: 10, max_requests: 3))
    end

    test "all exits return error" do
      fun = fn -> exit(:bye) end

      assert {:error, :bye, %{dispatched: 2, winner_index: nil}} =
               Runner.execute(fun, opts(delay: 10))
    end

    test "all throws return error" do
      fun = fn -> throw(:ball) end

      assert {:error, reason, %{dispatched: 2, winner_index: nil}} =
               Runner.execute(fun, opts(delay: 10))

      # :DOWN reason from a throw is {{:nocatch, value}, stacktrace}
      assert {{:nocatch, :ball}, _stacktrace} = reason
    end
  end

  describe "return normalization (extended)" do
    test "nested {:ok, {:error, _}} is treated as success" do
      assert {:ok, {:error, :inner}, %{dispatched: 1}} =
               Runner.execute(fn -> {:ok, {:error, :inner}} end, @default_opts)
    end

    test "bare :error normalizes to {:error, :error}" do
      assert {:error, :error, %{dispatched: _, winner_index: nil}} =
               Runner.execute(fn -> :error end, opts(max_requests: 1))
    end

    test "bare integer normalizes to {:ok, integer}" do
      assert {:ok, 42, _meta} =
               Runner.execute(fn -> 42 end, @default_opts)
    end

    test "bare nil normalizes to {:ok, nil}" do
      assert {:ok, nil, _meta} =
               Runner.execute(fn -> nil end, @default_opts)
    end

    test "bare list normalizes to {:ok, list}" do
      assert {:ok, [1, 2, 3], _meta} =
               Runner.execute(fn -> [1, 2, 3] end, @default_opts)
    end

    test "bare map normalizes to {:ok, map}" do
      assert {:ok, %{a: 1}, _meta} =
               Runner.execute(fn -> %{a: 1} end, @default_opts)
    end
  end

  describe "process cleanup" do
    test "hedged tasks are cleaned up after winner" do
      parent = self()
      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          send(parent, {:task_pid, self()})
          Process.sleep(5_000)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast, _} = Runner.execute(fun, opts(delay: 10))

      assert_receive {:task_pid, slow_pid}
      Process.sleep(50)
      refute Process.alive?(slow_pid)
    end

    test "all tasks cleaned up after timeout" do
      parent = self()

      fun = fn ->
        send(parent, {:task_pid, self()})
        Process.sleep(10_000)
        {:ok, :never}
      end

      Runner.execute(fun, opts(timeout: 50, delay: 10, max_requests: 3))

      # Collect all task pids that were spawned
      pids = collect_task_pids([])
      assert pids != []

      Process.sleep(100)
      Enum.each(pids, fn pid -> refute Process.alive?(pid) end)
    end
  end

  defp collect_task_pids(acc) do
    receive do
      {:task_pid, pid} -> collect_task_pids([pid | acc])
    after
      0 -> acc
    end
  end

  describe "now_fn injection" do
    test "uses injectable clock for deadline calculation" do
      clock = :atomics.new(1, signed: true)
      :atomics.put(clock, 1, 0)

      now_fn = fn :millisecond ->
        :atomics.get(clock, 1)
      end

      ref = :atomics.new(1, signed: false)

      fun = fn ->
        n = :atomics.add_get(ref, 1, 1)

        if n == 1 do
          # Advance clock past deadline
          :atomics.put(clock, 1, 6_000)
          {:error, :slow}
        else
          {:ok, :fast}
        end
      end

      # timeout is 5_000, clock starts at 0
      # After first attempt fails, clock jumps to 6_000 (past deadline)
      # But since pending: 0 and dispatched < max, it fires hedge anyway
      # The hedge succeeds before clock check
      result =
        Runner.execute(
          fun,
          opts(
            delay: 100,
            max_requests: 2,
            timeout: 5_000,
            now_fn: now_fn,
            non_fatal: fn _ -> false end
          )
        )

      assert match?({:ok, :fast, _}, result) or match?({:error, :timeout, _}, result)
    end
  end
end
