defmodule Resiliency.AllSettledTest do
  use ExUnit.Case, async: true

  doctest Resiliency.AllSettled

  describe "run/1,2" do
    test "all succeed — list of {:ok, result}" do
      results = Resiliency.AllSettled.run([fn -> 1 end, fn -> 2 end, fn -> 3 end])
      assert results == [{:ok, 1}, {:ok, 2}, {:ok, 3}]
    end

    test "mixed success/failure — preserves order" do
      results =
        Resiliency.AllSettled.run([
          fn -> 1 end,
          fn -> raise "boom" end,
          fn -> 3 end
        ])

      assert [{:ok, 1}, {:error, {%RuntimeError{message: "boom"}, _}}, {:ok, 3}] = results
    end

    test "all fail — list of {:error, reason}" do
      results =
        Resiliency.AllSettled.run([
          fn -> raise "one" end,
          fn -> exit(:two) end
        ])

      assert [{:error, {%RuntimeError{message: "one"}, _}}, {:error, :two}] = results
    end

    test "timeout — timed-out tasks get {:error, :timeout}" do
      results =
        Resiliency.AllSettled.run(
          [
            fn -> 1 end,
            fn -> Process.sleep(:infinity) end
          ],
          timeout: 100
        )

      assert [{:ok, 1}, {:error, :timeout}] = results
    end

    test "empty list → []" do
      assert [] = Resiliency.AllSettled.run([])
    end

    test "results are in input order, not completion order" do
      results =
        Resiliency.AllSettled.run([
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
      results = Resiliency.AllSettled.run([fn -> throw(:oops) end])
      assert [{:error, _}] = results
    end

    test "single function" do
      assert [{:ok, 42}] = Resiliency.AllSettled.run([fn -> 42 end])
    end

    test "never short-circuits — waits for all even after failures" do
      parent = self()

      results =
        Resiliency.AllSettled.run([
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
        result = Resiliency.AllSettled.run([fn -> exit(:brutal) end])
        send(parent, {:result, result})
      end)

      assert_receive {:result, [{:error, :brutal}]}, 1_000
    end

    test "all tasks timeout" do
      results =
        Resiliency.AllSettled.run(
          [
            fn -> Process.sleep(:infinity) end,
            fn -> Process.sleep(:infinity) end
          ],
          timeout: 50
        )

      assert [{:error, :timeout}, {:error, :timeout}] = results
    end
  end

  describe "process cleanup" do
    test "all_settled cleans up after completion" do
      parent = self()

      Resiliency.AllSettled.run([
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
  end
end
