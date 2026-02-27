defmodule Resiliency.RaceTest do
  use ExUnit.Case, async: true

  doctest Resiliency.Race

  describe "run/1,2" do
    test "returns first success when multiple succeed" do
      result =
        Resiliency.Race.run([
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
        Resiliency.Race.run([
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
               Resiliency.Race.run([
                 fn -> raise "boom" end,
                 fn -> exit(:crash) end,
                 fn -> throw(:oops) end
               ])
    end

    test "returns {:error, :timeout} on timeout" do
      assert {:error, :timeout} =
               Resiliency.Race.run(
                 [fn -> Process.sleep(:infinity) end],
                 timeout: 50
               )
    end

    test "shuts down remaining tasks after first success" do
      parent = self()

      Resiliency.Race.run([
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
      assert {:ok, 42} = Resiliency.Race.run([fn -> 42 end])
    end

    test "empty list returns {:error, :empty}" do
      assert {:error, :empty} = Resiliency.Race.run([])
    end

    test "returns success even when it finishes after a failure" do
      assert {:ok, :winner} =
               Resiliency.Race.run([
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
        result = Resiliency.Race.run([fn -> exit(:brutal) end, fn -> :ok end])
        send(parent, {:result, result})
      end)

      assert_receive {:result, {:ok, :ok}}, 1_000
    end

    test "timeout with mix of failures and slow tasks" do
      assert {:error, :timeout} =
               Resiliency.Race.run(
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

      Resiliency.Race.run([
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

      assert {:ok, result} = Resiliency.Race.run(funs)
      assert result in 1..100
    end
  end

  describe "process cleanup" do
    test "race cleans up cancelled tasks" do
      parent = self()

      Resiliency.Race.run([
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

    test "race task crashes do not leak monitors" do
      # Run many races with crashing tasks to check for monitor leaks
      for _ <- 1..50 do
        Resiliency.Race.run([
          fn -> raise "boom" end,
          fn -> :ok end
        ])
      end

      # If monitors leaked, the process mailbox would have stale :DOWN messages
      refute_receive {:DOWN, _, _, _, _}, 0
    end
  end
end
