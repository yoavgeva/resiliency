defmodule Resiliency.TaskExtensionTest do
  use ExUnit.Case, async: true

  doctest Resiliency.TaskExtension

  describe "race/1,2" do
    test "returns first success when multiple succeed" do
      result =
        Resiliency.TaskExtension.race([
          fn ->
            Process.sleep(100)
            :slow
          end,
          fn -> :fast end,
          fn ->
            Process.sleep(200)
            :slowest
          end
        ])

      assert {:ok, :fast} = result
    end

    test "returns first success even if earlier tasks crash" do
      result =
        Resiliency.TaskExtension.race([
          fn -> raise "boom" end,
          fn ->
            Process.sleep(50)
            :ok
          end
        ])

      assert {:ok, :ok} = result
    end

    test "returns {:error, :all_failed} when all fail" do
      assert {:error, :all_failed} =
               Resiliency.TaskExtension.race([
                 fn -> raise "boom" end,
                 fn -> exit(:crash) end,
                 fn -> throw(:oops) end
               ])
    end

    test "returns {:error, :timeout} on timeout" do
      assert {:error, :timeout} =
               Resiliency.TaskExtension.race(
                 [fn -> Process.sleep(:infinity) end],
                 timeout: 50
               )
    end

    test "shuts down remaining tasks after first success" do
      parent = self()

      Resiliency.TaskExtension.race([
        fn ->
          Process.sleep(50)
          send(parent, :slow_completed)
          :slow
        end,
        fn -> :fast end
      ])

      Process.sleep(150)
      refute_received :slow_completed
    end

    test "works with single function" do
      assert {:ok, 42} = Resiliency.TaskExtension.race([fn -> 42 end])
    end

    test "empty list returns {:error, :empty}" do
      assert {:error, :empty} = Resiliency.TaskExtension.race([])
    end

    test "returns success even when it finishes after a failure" do
      assert {:ok, :winner} =
               Resiliency.TaskExtension.race([
                 fn -> raise "immediate fail" end,
                 fn ->
                   Process.sleep(20)
                   :winner
                 end
               ])
    end

    test "task crash does not crash the caller" do
      parent = self()

      spawn(fn ->
        result = Resiliency.TaskExtension.race([fn -> exit(:brutal) end, fn -> :ok end])
        send(parent, {:result, result})
      end)

      assert_receive {:result, {:ok, :ok}}, 1_000
    end

    test "timeout with mix of failures and slow tasks" do
      assert {:error, :timeout} =
               Resiliency.TaskExtension.race(
                 [
                   fn -> raise "fast fail" end,
                   fn ->
                     Process.sleep(:infinity)
                     :never
                   end
                 ],
                 timeout: 50
               )
    end

    test "ignores late results after first success" do
      parent = self()

      Resiliency.TaskExtension.race([
        fn -> :immediate end,
        fn ->
          Process.sleep(50)
          send(parent, :late_result)
          :late
        end
      ])

      Process.sleep(150)
      refute_received :late_result
    end

    test "many concurrent tasks" do
      funs =
        for i <- 1..100,
            do: fn ->
              Process.sleep(i)
              i
            end

      assert {:ok, result} = Resiliency.TaskExtension.race(funs)
      assert result in 1..100
    end
  end

  describe "all_settled/1,2" do
    test "all succeed — list of {:ok, result}" do
      results = Resiliency.TaskExtension.all_settled([fn -> 1 end, fn -> 2 end, fn -> 3 end])
      assert results == [{:ok, 1}, {:ok, 2}, {:ok, 3}]
    end

    test "mixed success/failure — preserves order" do
      results =
        Resiliency.TaskExtension.all_settled([
          fn -> 1 end,
          fn -> raise "boom" end,
          fn -> 3 end
        ])

      assert [{:ok, 1}, {:error, {%RuntimeError{message: "boom"}, _}}, {:ok, 3}] = results
    end

    test "all fail — list of {:error, reason}" do
      results =
        Resiliency.TaskExtension.all_settled([
          fn -> raise "one" end,
          fn -> exit(:two) end
        ])

      assert [{:error, {%RuntimeError{message: "one"}, _}}, {:error, :two}] = results
    end

    test "timeout — timed-out tasks get {:error, :timeout}" do
      results =
        Resiliency.TaskExtension.all_settled(
          [
            fn -> 1 end,
            fn -> Process.sleep(:infinity) end
          ],
          timeout: 100
        )

      assert [{:ok, 1}, {:error, :timeout}] = results
    end

    test "empty list → []" do
      assert [] = Resiliency.TaskExtension.all_settled([])
    end

    test "results are in input order, not completion order" do
      results =
        Resiliency.TaskExtension.all_settled([
          fn ->
            Process.sleep(80)
            :first
          end,
          fn ->
            Process.sleep(40)
            :second
          end,
          fn -> :third end
        ])

      assert [{:ok, :first}, {:ok, :second}, {:ok, :third}] = results
    end

    test "handles throws as failures" do
      results = Resiliency.TaskExtension.all_settled([fn -> throw(:oops) end])
      assert [{:error, _}] = results
    end

    test "single function" do
      assert [{:ok, 42}] = Resiliency.TaskExtension.all_settled([fn -> 42 end])
    end

    test "never short-circuits — waits for all even after failures" do
      parent = self()

      results =
        Resiliency.TaskExtension.all_settled([
          fn -> raise "fast fail" end,
          fn ->
            Process.sleep(50)
            send(parent, :second_ran)
            :second
          end
        ])

      assert [{:error, _}, {:ok, :second}] = results
      assert_received :second_ran
    end

    test "task crash does not crash the caller" do
      parent = self()

      spawn(fn ->
        result = Resiliency.TaskExtension.all_settled([fn -> exit(:brutal) end])
        send(parent, {:result, result})
      end)

      assert_receive {:result, [{:error, :brutal}]}, 1_000
    end

    test "all tasks timeout" do
      results =
        Resiliency.TaskExtension.all_settled(
          [
            fn -> Process.sleep(:infinity) end,
            fn -> Process.sleep(:infinity) end
          ],
          timeout: 50
        )

      assert [{:error, :timeout}, {:error, :timeout}] = results
    end
  end

  describe "map/2,3" do
    test "maps over enumerable with bounded concurrency" do
      assert {:ok, [2, 4, 6]} =
               Resiliency.TaskExtension.map([1, 2, 3], &(&1 * 2), max_concurrency: 2)
    end

    test "returns {:ok, results} in input order" do
      result =
        Resiliency.TaskExtension.map([3, 1, 2], fn x ->
          Process.sleep(x * 20)
          x * 10
        end)

      assert {:ok, [30, 10, 20]} = result
    end

    test "cancels remaining on first error, returns {:error, reason}" do
      parent = self()

      result =
        Resiliency.TaskExtension.map(
          [1, 2, 3],
          fn
            2 ->
              raise "boom"

            x ->
              Process.sleep(100)
              send(parent, {:completed, x})
              x
          end,
          max_concurrency: 3
        )

      assert {:error, {%RuntimeError{message: "boom"}, _}} = result

      Process.sleep(200)
      refute_received {:completed, _}
    end

    test "respects max_concurrency limit" do
      counter = :counters.new(1, [])
      max_seen = :atomics.new(1, [])

      Resiliency.TaskExtension.map(
        1..10,
        fn _ ->
          :counters.add(counter, 1, 1)
          current = :counters.get(counter, 1)

          loop_max = :atomics.get(max_seen, 1)
          if current > loop_max, do: :atomics.put(max_seen, 1, current)

          Process.sleep(20)
          :counters.add(counter, 1, -1)
        end,
        max_concurrency: 3
      )

      assert :atomics.get(max_seen, 1) <= 3
    end

    test "timeout support" do
      result =
        Resiliency.TaskExtension.map(
          [1, 2, 3],
          fn _ -> Process.sleep(:infinity) end,
          timeout: 50
        )

      assert {:error, :timeout} = result
    end

    test "empty enumerable → {:ok, []}" do
      assert {:ok, []} = Resiliency.TaskExtension.map([], fn x -> x end)
    end

    test "works with non-list enumerables" do
      assert {:ok, [2, 4, 6]} = Resiliency.TaskExtension.map(1..3, &(&1 * 2))
    end

    test "default max_concurrency is System.schedulers_online()" do
      # Just verify it works without specifying max_concurrency
      assert {:ok, [1, 2, 3]} = Resiliency.TaskExtension.map([1, 2, 3], & &1)
    end

    test "single element" do
      assert {:ok, [42]} = Resiliency.TaskExtension.map([21], &(&1 * 2))
    end

    test "max_concurrency: 1 runs sequentially" do
      order = :atomics.new(1, [])

      {:ok, results} =
        Resiliency.TaskExtension.map(
          [1, 2, 3],
          fn x ->
            pos = :atomics.add_get(order, 1, 1)
            {x, pos}
          end,
          max_concurrency: 1
        )

      # With max_concurrency 1, execution order matches input order
      assert [{1, 1}, {2, 2}, {3, 3}] = results
    end

    test "max_concurrency greater than item count" do
      assert {:ok, [2, 4, 6]} =
               Resiliency.TaskExtension.map([1, 2, 3], &(&1 * 2), max_concurrency: 100)
    end

    test "handles exit failures" do
      result =
        Resiliency.TaskExtension.map(
          [1, 2, 3],
          fn
            2 -> exit(:crash)
            x -> x
          end,
          max_concurrency: 3
        )

      assert {:error, :crash} = result
    end

    test "handles throw failures" do
      result =
        Resiliency.TaskExtension.map(
          [1, 2, 3],
          fn
            2 -> throw(:oops)
            x -> x
          end,
          max_concurrency: 3
        )

      assert {:error, _} = result
    end

    test "pending items not started after error" do
      parent = self()

      Resiliency.TaskExtension.map(
        1..10,
        fn
          1 ->
            raise "boom"

          x ->
            send(parent, {:started, x})
            x
        end,
        max_concurrency: 1
      )

      Process.sleep(50)
      # With max_concurrency: 1, item 1 fails before any others start
      refute_received {:started, _}
    end

    test "large batch with bounded concurrency" do
      {:ok, results} = Resiliency.TaskExtension.map(1..100, &(&1 * 2), max_concurrency: 5)
      assert results == Enum.map(1..100, &(&1 * 2))
    end
  end

  describe "first_ok/1,2" do
    test "returns first success" do
      assert {:ok, :hello} = Resiliency.TaskExtension.first_ok([fn -> :hello end])
    end

    test "skips failures, returns later success" do
      assert {:ok, :second} =
               Resiliency.TaskExtension.first_ok([
                 fn -> raise "boom" end,
                 fn -> :second end
               ])
    end

    test "returns {:error, :all_failed} when all fail" do
      assert {:error, :all_failed} =
               Resiliency.TaskExtension.first_ok([
                 fn -> raise "one" end,
                 fn -> exit(:two) end,
                 fn -> throw(:three) end
               ])
    end

    test "treats {:error, _} return values as failures" do
      assert {:ok, :winner} =
               Resiliency.TaskExtension.first_ok([
                 fn -> {:error, :miss} end,
                 fn -> :winner end
               ])
    end

    test "passes through {:ok, value} return values" do
      assert {:ok, "found"} =
               Resiliency.TaskExtension.first_ok([
                 fn -> {:error, :miss} end,
                 fn -> {:ok, "found"} end
               ])
    end

    test "treats raises as failures" do
      assert {:ok, :ok} =
               Resiliency.TaskExtension.first_ok([
                 fn -> raise "boom" end,
                 fn -> :ok end
               ])
    end

    test "treats exits as failures" do
      assert {:ok, :ok} =
               Resiliency.TaskExtension.first_ok([
                 fn -> exit(:crash) end,
                 fn -> :ok end
               ])
    end

    test "treats throws as failures" do
      assert {:ok, :ok} =
               Resiliency.TaskExtension.first_ok([
                 fn -> throw(:oops) end,
                 fn -> :ok end
               ])
    end

    test "empty list → {:error, :empty}" do
      assert {:error, :empty} = Resiliency.TaskExtension.first_ok([])
    end

    test "wraps non-tuple return values in {:ok, _}" do
      assert {:ok, 42} = Resiliency.TaskExtension.first_ok([fn -> 42 end])
      assert {:ok, "hello"} = Resiliency.TaskExtension.first_ok([fn -> "hello" end])
      assert {:ok, [1, 2]} = Resiliency.TaskExtension.first_ok([fn -> [1, 2] end])
    end

    test "timeout stops trying remaining functions" do
      parent = self()

      result =
        Resiliency.TaskExtension.first_ok(
          [
            fn ->
              Process.sleep(200)
              {:error, :slow}
            end,
            fn ->
              send(parent, :second_tried)
              :should_not_reach
            end
          ],
          timeout: 50
        )

      assert {:error, :all_failed} = result
      refute_received :second_tried
    end

    test "returns first success after many prior failures" do
      funs =
        List.duplicate(fn -> {:error, :nope} end, 10) ++
          [fn -> :winner end] ++
          List.duplicate(fn -> :should_not_reach end, 5)

      assert {:ok, :winner} = Resiliency.TaskExtension.first_ok(funs)
    end

    test "nil return value wrapped correctly" do
      assert {:ok, nil} = Resiliency.TaskExtension.first_ok([fn -> nil end])
    end

    test "{:ok, nil} passthrough" do
      assert {:ok, nil} = Resiliency.TaskExtension.first_ok([fn -> {:ok, nil} end])
    end

    test "does not execute functions after first success" do
      parent = self()

      Resiliency.TaskExtension.first_ok([
        fn -> :winner end,
        fn ->
          send(parent, :should_not_run)
          :second
        end
      ])

      Process.sleep(50)
      refute_received :should_not_run
    end
  end

  describe "process cleanup" do
    test "race cleans up cancelled tasks" do
      parent = self()

      Resiliency.TaskExtension.race([
        fn ->
          send(parent, {:pid, self()})
          Process.sleep(5_000)
          :slow
        end,
        fn -> :fast end
      ])

      assert_receive {:pid, slow_pid}
      Process.sleep(50)
      refute Process.alive?(slow_pid)
    end

    test "all_settled cleans up after completion" do
      parent = self()

      Resiliency.TaskExtension.all_settled([
        fn ->
          send(parent, {:pid, self()})
          1
        end,
        fn -> raise "boom" end,
        fn -> 3 end
      ])

      assert_receive {:pid, pid}
      Process.sleep(50)
      refute Process.alive?(pid)
    end

    test "map cleans up after error" do
      parent = self()

      Resiliency.TaskExtension.map(
        1..5,
        fn
          3 ->
            raise "boom"

          x ->
            send(parent, {:pid, self()})
            Process.sleep(5_000)
            x
        end,
        max_concurrency: 5
      )

      # Collect tracked pids
      pids = collect_pids([])
      assert pids != []

      Process.sleep(100)
      Enum.each(pids, fn pid -> refute Process.alive?(pid) end)
    end

    test "race task crashes do not leak monitors" do
      # Run many races with crashing tasks to check for monitor leaks
      for _ <- 1..50 do
        Resiliency.TaskExtension.race([
          fn -> raise "boom" end,
          fn -> :ok end
        ])
      end

      # If monitors leaked, the process mailbox would have stale :DOWN messages
      refute_receive {:DOWN, _, _, _, _}, 0
    end
  end

  defp collect_pids(acc) do
    receive do
      {:pid, pid} -> collect_pids([pid | acc])
    after
      0 -> acc
    end
  end
end
