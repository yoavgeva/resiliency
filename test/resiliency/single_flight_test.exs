defmodule Resiliency.SingleFlightTest do
  use ExUnit.Case, async: true

  setup do
    server =
      start_supervised!(
        {Resiliency.SingleFlight, name: :"sf_#{System.unique_integer([:positive])}"}
      )

    %{server: server}
  end

  describe "flight/3" do
    test "returns the result of the function", %{server: server} do
      assert {:ok, 42} = Resiliency.SingleFlight.flight(server, "key", fn -> 42 end)
    end

    test "executes separately for different keys", %{server: server} do
      counter = :counters.new(1, [:atomics])

      task1 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "key-a", fn ->
            :counters.add(counter, 1, 1)
            :a
          end)
        end)

      task2 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "key-b", fn ->
            :counters.add(counter, 1, 1)
            :b
          end)
        end)

      assert {:ok, :a} = Task.await(task1)
      assert {:ok, :b} = Task.await(task2)
      assert :counters.get(counter, 1) == 2
    end

    test "propagates error when function raises", %{server: server} do
      result =
        Resiliency.SingleFlight.flight(server, "raise-key", fn ->
          raise "boom"
        end)

      assert {:error, {%RuntimeError{message: "boom"}, _stacktrace}} = result
    end

    test "propagates error when function exits", %{server: server} do
      result =
        Resiliency.SingleFlight.flight(server, "exit-key", fn ->
          exit(:kaboom)
        end)

      assert {:error, {:exit, :kaboom}} = result
    end

    test "propagates error when function throws", %{server: server} do
      result =
        Resiliency.SingleFlight.flight(server, "throw-key", fn ->
          throw(:yeet)
        end)

      assert {:error, {:throw, :yeet}} = result
    end

    test "key can be reused after completion", %{server: server} do
      assert {:ok, 1} = Resiliency.SingleFlight.flight(server, "reuse", fn -> 1 end)
      assert {:ok, 2} = Resiliency.SingleFlight.flight(server, "reuse", fn -> 2 end)
    end

    test "wraps fn return value in :ok tuple, even if fn returns error-like values", %{
      server: server
    } do
      assert {:ok, {:error, :not_found}} =
               Resiliency.SingleFlight.flight(server, "err-val", fn -> {:error, :not_found} end)

      assert {:ok, nil} = Resiliency.SingleFlight.flight(server, "nil-val", fn -> nil end)
    end
  end

  describe "flight/4 with timeout" do
    test "caller exits on timeout but function keeps running", %{server: server} do
      counter = :counters.new(1, [:atomics])

      assert catch_exit(
               Resiliency.SingleFlight.flight(
                 server,
                 "timeout-key",
                 fn ->
                   Process.sleep(500)
                   :counters.add(counter, 1, 1)
                   :done
                 end,
                 50
               )
             )

      # Wait for the function to complete
      Process.sleep(600)

      # Function still executed to completion
      assert :counters.get(counter, 1) == 1

      # Key is cleared — new call works
      assert {:ok, :fresh} =
               Resiliency.SingleFlight.flight(server, "timeout-key", fn -> :fresh end)
    end
  end

  describe "deduplication" do
    test "concurrent calls with same key execute fn only once", %{server: server} do
      counter = :counters.new(1, [:atomics])
      gate = gate_open()

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "dedup", fn ->
              :counters.add(counter, 1, 1)
              gate_await(gate)
              :result
            end)
          end)
        end

      # Give time for all callers to register
      Process.sleep(100)

      # Open the gate
      gate_release(gate)

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, &(&1 == {:ok, :result}))
      assert :counters.get(counter, 1) == 1
    end

    test "error propagates to all waiting callers", %{server: server} do
      gate = gate_open()

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "error-dedup", fn ->
              gate_await(gate)
              raise "boom"
            end)
          end)
        end

      Process.sleep(100)
      gate_release(gate)

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn
               {:error, {%RuntimeError{message: "boom"}, _stacktrace}} -> true
               _ -> false
             end)
    end
  end

  describe "forget/2" do
    test "causes next call to start fresh execution", %{server: server} do
      counter = :counters.new(1, [:atomics])
      gate = gate_open()

      # Start an in-flight call that blocks on the gate
      task1 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "forget-key", fn ->
            :counters.add(counter, 1, 1)
            gate_await(gate)
            :first
          end)
        end)

      # Give time for the flight to register and fn to start
      Process.sleep(100)

      # Forget the key — next call will start fresh
      :ok = Resiliency.SingleFlight.forget(server, "forget-key")

      # New call with same key starts a fresh execution
      task2 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "forget-key", fn ->
            :counters.add(counter, 1, 1)
            :second
          end)
        end)

      # task2 should complete immediately (its fn doesn't block)
      assert {:ok, :second} = Task.await(task2, 5000)

      # Release the gate so task1 completes
      gate_release(gate)
      assert {:ok, :first} = Task.await(task1, 5000)

      # Function ran twice (once for each flight)
      assert :counters.get(counter, 1) == 2
    end

    test "after forget, third caller deduplicates with the second call, not the first",
         %{server: server} do
      gate1 = gate_open()
      gate2 = gate_open()

      # First call — blocks on gate1
      task1 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "key", fn ->
            gate_await(gate1)
            :first
          end)
        end)

      Process.sleep(50)

      # Forget the key while first is in-flight
      :ok = Resiliency.SingleFlight.forget(server, "key")

      # Second call — starts fresh, blocks on gate2
      task2 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "key", fn ->
            gate_await(gate2)
            :second
          end)
        end)

      Process.sleep(50)

      # Third call — should deduplicate with the second (not the first)
      task3 =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "key", fn ->
            :third_should_not_run
          end)
        end)

      Process.sleep(50)

      # Release first call — task1 gets :first
      gate_release(gate1)
      assert {:ok, :first} = Task.await(task1, 5000)

      # Release second call — task2 AND task3 get :second
      gate_release(gate2)
      assert {:ok, :second} = Task.await(task2, 5000)
      assert {:ok, :second} = Task.await(task3, 5000)
    end

    test "forget on unknown key is a no-op", %{server: server} do
      assert :ok = Resiliency.SingleFlight.forget(server, "nonexistent")
    end
  end

  describe "raise propagation (TestPanicDo equivalent)" do
    test "all concurrent callers receive the error when fn raises", %{server: server} do
      gate = gate_open()
      n = 5

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "panic-key", fn ->
              gate_await(gate)
              raise "invalid memory address or nil pointer dereference"
            end)
          end)
        end

      Process.sleep(100)
      gate_release(gate)

      results = Task.await_many(tasks, 5000)

      # Every caller got an error
      assert length(results) == n

      Enum.each(results, fn result ->
        assert {:error, {%RuntimeError{}, _stacktrace}} = result
      end)
    end

    test "server remains functional after fn raises", %{server: server} do
      _err =
        Resiliency.SingleFlight.flight(server, "crash", fn ->
          raise "oops"
        end)

      # Server should still work
      assert {:ok, :alive} =
               Resiliency.SingleFlight.flight(server, "after-crash", fn -> :alive end)
    end
  end

  describe "external kill (:DOWN handler)" do
    test "returns error when in-flight task is killed externally", %{server: server} do
      gate = gate_open()

      # Start a flight that blocks on the gate
      caller =
        Task.async(fn ->
          Resiliency.SingleFlight.flight(server, "kill-key", fn ->
            gate_await(gate)
            :should_not_reach
          end)
        end)

      # Give time for the flight to register and the task to start
      Process.sleep(100)

      # Extract the task PID from the GenServer state
      %{calls: calls} = :sys.get_state(server)
      %{task_pid: task_pid} = Map.fetch!(calls, "kill-key")

      # Kill the task with an untrappable signal — this bypasses execute/1's
      # rescue/catch and triggers the :DOWN handler in the server
      Process.exit(task_pid, :kill)

      # The caller should receive {:error, :killed} from the :DOWN handler
      assert {:error, :killed} = Task.await(caller, 5000)

      # Server should still be functional after an external kill
      assert {:ok, :alive} =
               Resiliency.SingleFlight.flight(server, "after-kill", fn -> :alive end)
    end

    test "external kill propagates to all waiting callers", %{server: server} do
      gate = gate_open()

      # Start multiple callers on the same key
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "kill-multi", fn ->
              gate_await(gate)
              :should_not_reach
            end)
          end)
        end

      # Give time for all callers to register
      Process.sleep(100)

      # Extract the task PID from the GenServer state
      %{calls: calls} = :sys.get_state(server)
      %{task_pid: task_pid} = Map.fetch!(calls, "kill-multi")

      # Kill the task externally
      Process.exit(task_pid, :kill)

      results = Task.await_many(tasks, 5000)

      # All callers should receive the :killed error
      assert Enum.all?(results, &(&1 == {:error, :killed}))
    end
  end

  describe "stress" do
    test "100 concurrent callers with same key, fn runs once", %{server: server} do
      counter = :counters.new(1, [:atomics])

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "stress", fn ->
              :counters.add(counter, 1, 1)
              Process.sleep(50)
              :ok
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, &(&1 == {:ok, :ok}))
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "high-concurrency key dedup" do
    test "many distinct keys resolve correctly with reverse index", %{server: server} do
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "key-#{i}", fn ->
              Process.sleep(10)
              i
            end)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 100

      Enum.each(Enum.with_index(results, 1), fn {result, i} ->
        assert {:ok, ^i} = result
      end)
    end

    test "mixed concurrent keys with dedup and distinct keys", %{server: server} do
      counter = :counters.new(1, [:atomics])
      gate = gate_open()

      # 50 callers on same key, 50 on distinct keys
      dedup_tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "shared", fn ->
              :counters.add(counter, 1, 1)
              gate_await(gate)
              :shared_result
            end)
          end)
        end

      distinct_tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "distinct-#{i}", fn ->
              i
            end)
          end)
        end

      # Distinct tasks complete immediately
      distinct_results = Task.await_many(distinct_tasks, 10_000)

      assert Enum.all?(distinct_results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Release shared gate
      Process.sleep(50)
      gate_release(gate)

      dedup_results = Task.await_many(dedup_tasks, 10_000)
      assert Enum.all?(dedup_results, &(&1 == {:ok, :shared_result}))
      assert :counters.get(counter, 1) == 1
    end
  end

  # -- Gate helpers --
  # A gate is an :atomics ref that starts closed (0) and opens (1).
  # Processes poll until the gate opens. Simple and no PID coordination needed.

  defp gate_open do
    ref = :atomics.new(1, [])
    :atomics.put(ref, 1, 0)
    ref
  end

  defp gate_release(ref) do
    :atomics.put(ref, 1, 1)
  end

  defp gate_await(ref) do
    if :atomics.get(ref, 1) == 1 do
      :ok
    else
      Process.sleep(10)
      gate_await(ref)
    end
  end
end
