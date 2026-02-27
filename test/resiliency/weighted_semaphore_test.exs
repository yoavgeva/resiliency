defmodule Resiliency.WeightedSemaphoreTest do
  use ExUnit.Case, async: true
  doctest Resiliency.WeightedSemaphore

  describe "basic acquire" do
    test "acquires weight 1 and returns result" do
      sem = start_sem!(max: 3)
      assert {:ok, 42} = Resiliency.WeightedSemaphore.acquire(sem, fn -> 42 end)
    end

    test "acquires weight N and returns result" do
      sem = start_sem!(max: 5)
      assert {:ok, :done} = Resiliency.WeightedSemaphore.acquire(sem, 3, fn -> :done end)
    end

    test "blocks when insufficient capacity and resumes when freed" do
      sem = start_sem!(max: 2)
      gate = gate_new()

      # Fill up the semaphore
      task =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 2, fn ->
            gate_wait(gate)
            :first
          end)
        end)

      # Wait until the first task is running
      wait_until(fn -> current(sem) == 2 end)

      # This should block
      blocked =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :second end)
        end)

      # Give it time to actually block
      Process.sleep(50)
      refute_done(blocked)

      # Release first task
      gate_open(gate)
      assert {:ok, :first} = Task.await(task)
      assert {:ok, :second} = Task.await(blocked)
    end
  end

  describe "weighted permits" do
    test "mixed weight operations respect total capacity" do
      sem = start_sem!(max: 10)
      gate = gate_new()

      # Acquire 7 of 10
      holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 7, fn ->
            gate_wait(gate)
            :held
          end)
        end)

      wait_until(fn -> current(sem) == 7 end)

      # Acquire 3 more — should succeed (7 + 3 = 10)
      assert {:ok, :fits} = Resiliency.WeightedSemaphore.acquire(sem, 3, fn -> :fits end)

      gate_open(gate)
      assert {:ok, :held} = Task.await(holder)
    end

    test "weight exceeds max returns error immediately" do
      sem = start_sem!(max: 5)

      assert {:error, :weight_exceeds_max} =
               Resiliency.WeightedSemaphore.acquire(sem, 6, fn -> :never end)
    end

    test "invalid weight returns error" do
      sem = start_sem!(max: 5)

      assert {:error, :invalid_weight} =
               Resiliency.WeightedSemaphore.acquire(sem, 0, fn -> :never end)

      assert {:error, :invalid_weight} =
               Resiliency.WeightedSemaphore.acquire(sem, -1, fn -> :never end)
    end
  end

  describe "auto-release" do
    test "permits freed after fn completes" do
      sem = start_sem!(max: 1)

      assert {:ok, :a} = Resiliency.WeightedSemaphore.acquire(sem, fn -> :a end)
      # If permits weren't released, this would block forever
      assert {:ok, :b} = Resiliency.WeightedSemaphore.acquire(sem, fn -> :b end)
    end

    @tag capture_log: true
    test "permits freed after fn raises" do
      sem = start_sem!(max: 1)

      assert {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
               Resiliency.WeightedSemaphore.acquire(sem, fn -> raise "boom" end)

      # Permits should be freed despite the crash
      assert {:ok, :ok} = Resiliency.WeightedSemaphore.acquire(sem, fn -> :ok end)
    end

    @tag capture_log: true
    test "permits freed after fn exits" do
      sem = start_sem!(max: 1)

      assert {:error, :custom_exit} =
               Resiliency.WeightedSemaphore.acquire(sem, fn -> exit(:custom_exit) end)

      assert {:ok, :ok} = Resiliency.WeightedSemaphore.acquire(sem, fn -> :ok end)
    end

    @tag capture_log: true
    test "permits freed after fn throws" do
      sem = start_sem!(max: 1)

      assert {:error, {{:nocatch, :thrown_value}, _stacktrace}} =
               Resiliency.WeightedSemaphore.acquire(sem, fn -> throw(:thrown_value) end)

      assert {:ok, :ok} = Resiliency.WeightedSemaphore.acquire(sem, fn -> :ok end)
    end
  end

  describe "FIFO fairness / starvation prevention" do
    test "large waiter at front blocks smaller waiters behind it" do
      sem = start_sem!(max: 10)
      gate = gate_new()

      # Hold 5 permits
      holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 5, fn ->
            gate_wait(gate)
            :held
          end)
        end)

      wait_until(fn -> current(sem) == 5 end)

      # Queue a weight-8 waiter (needs 8, only 5 available after holder)
      # Actually needs 8 total, holder has 5, so only 5 remain — 8 doesn't fit.
      large =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 8, fn -> :large end)
        end)

      Process.sleep(50)

      # Queue a weight-1 waiter — should ALSO block (FIFO fairness)
      small =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :small end)
        end)

      Process.sleep(50)

      refute_done(large)
      refute_done(small)

      # Release holder — frees 5 permits
      # Now we have 10 available. Large (8) fits → runs.
      gate_open(gate)
      assert {:ok, :held} = Task.await(holder)

      # Large should complete, then small should run
      assert {:ok, :large} = Task.await(large)
      assert {:ok, :small} = Task.await(small)
    end

    test "queue ordering is FIFO" do
      sem = start_sem!(max: 1)
      gate = gate_new()
      order_agent = start_agent!([])

      # Hold the only permit
      holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
            gate_wait(gate)
            :held
          end)
        end)

      wait_until(fn -> current(sem) == 1 end)

      # Queue waiters one at a time, waiting for each to enter the queue
      # before spawning the next — ensures deterministic FIFO order.
      tasks =
        for i <- 1..5 do
          expected_queued = i

          task =
            Task.async(fn ->
              Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
                Agent.update(order_agent, &[i | &1])
                i
              end)
            end)

          wait_until(fn -> waiter_count(sem) == expected_queued end)
          task
        end

      gate_open(gate)
      assert {:ok, :held} = Task.await(holder)

      for task <- tasks, do: Task.await(task)

      order = Agent.get(order_agent, &Enum.reverse/1)
      assert order == [1, 2, 3, 4, 5]
    end
  end

  describe "oversized request doesn't block others" do
    test "weight > max rejects immediately without blocking smaller waiters" do
      sem = start_sem!(max: 5)
      gate = gate_new()

      # Fill the semaphore
      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 5, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 5 end)

      # Queue a small waiter
      small =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :small_done end)
        end)

      Process.sleep(50)

      # Oversized request should fail immediately, not affect queue
      assert {:error, :weight_exceeds_max} =
               Resiliency.WeightedSemaphore.acquire(sem, 6, fn -> :never end)

      # Small waiter should still complete once capacity is freed
      gate_open(gate)
      assert {:ok, :small_done} = Task.await(small)
    end
  end

  describe "try_acquire" do
    test "succeeds when capacity available" do
      sem = start_sem!(max: 3)
      assert {:ok, :done} = Resiliency.WeightedSemaphore.try_acquire(sem, fn -> :done end)
    end

    test "returns :rejected when no capacity" do
      sem = start_sem!(max: 1)
      gate = gate_new()

      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 1 end)

      assert :rejected = Resiliency.WeightedSemaphore.try_acquire(sem, fn -> :never end)

      gate_open(gate)
    end

    test "returns :rejected when waiters are queued" do
      sem = start_sem!(max: 2)
      gate = gate_new()

      # Fill capacity
      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 2, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 2 end)

      # Queue a waiter
      _waiter =
        Task.async(fn -> Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :queued end) end)

      Process.sleep(50)

      # try_acquire should be rejected even if capacity existed — queue is not empty
      assert :rejected = Resiliency.WeightedSemaphore.try_acquire(sem, 1, fn -> :never end)

      gate_open(gate)
    end

    test "weighted try_acquire" do
      sem = start_sem!(max: 5)
      gate = gate_new()

      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 3, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 3 end)

      # 2 permits free, try to get 3 — should be rejected
      assert :rejected = Resiliency.WeightedSemaphore.try_acquire(sem, 3, fn -> :never end)

      # 2 permits free, try to get 2 — should work
      assert {:ok, :fits} = Resiliency.WeightedSemaphore.try_acquire(sem, 2, fn -> :fits end)

      gate_open(gate)
    end

    test "invalid weight returns error" do
      sem = start_sem!(max: 5)

      assert {:error, :invalid_weight} =
               Resiliency.WeightedSemaphore.try_acquire(sem, 0, fn -> :never end)

      assert {:error, :invalid_weight} =
               Resiliency.WeightedSemaphore.try_acquire(sem, -1, fn -> :never end)
    end

    test "weight exceeds max returns error immediately" do
      sem = start_sem!(max: 5)

      assert {:error, :weight_exceeds_max} =
               Resiliency.WeightedSemaphore.try_acquire(sem, 6, fn -> :never end)
    end
  end

  describe "timeout" do
    test "returns {:error, :timeout} when timeout expires" do
      sem = start_sem!(max: 1)
      gate = gate_new()

      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 1 end)

      assert {:error, :timeout} =
               Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :never end, 100)

      gate_open(gate)
    end

    test "zombie waiter's function is not executed after caller times out and dies" do
      sem = start_sem!(max: 1)
      gate = gate_new()
      zombie_executed = start_agent!(false)

      # Hold the only permit
      holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
            gate_wait(gate)
            :held
          end)
        end)

      wait_until(fn -> current(sem) == 1 end)

      # Spawn a process that will timeout and then die
      caller =
        spawn(fn ->
          Resiliency.WeightedSemaphore.acquire(
            sem,
            1,
            fn ->
              Agent.update(zombie_executed, fn _ -> true end)
              :zombie
            end,
            100
          )

          # After timeout, process exits naturally
        end)

      # Wait for the caller to timeout and die
      ref = Process.monitor(caller)
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 5_000

      # Now release the holder — this triggers notify_waiters
      gate_open(gate)
      assert {:ok, :held} = Task.await(holder)

      # Give the server time to process waiters
      Process.sleep(100)

      # The zombie waiter's function should NOT have been executed
      refute Agent.get(zombie_executed, & &1),
             "zombie waiter's function was executed despite caller being dead"

      # Permits should be fully released (no permits wasted on zombie)
      assert current(sem) == 0
    end

    test "caller timeout doesn't starve other waiters" do
      sem = start_sem!(max: 1)
      gate = gate_new()

      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 1 end)

      # This waiter will timeout
      assert {:error, :timeout} =
               Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :timed_out end, 100)

      # This waiter should still eventually get served
      other =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :served end)
        end)

      Process.sleep(50)
      gate_open(gate)
      assert {:ok, :served} = Task.await(other)
    end
  end

  describe "stress test" do
    test "concurrent acquire/release with random weights" do
      sem = start_sem!(max: 10)
      n = 100

      tasks =
        for i <- 1..n do
          weight = rem(i, 10) + 1

          Task.async(fn ->
            {:ok, result} =
              Resiliency.WeightedSemaphore.acquire(sem, weight, fn ->
                # Simulate some work
                Process.sleep(Enum.random(1..5))
                i
              end)

            result
          end)
        end

      results = tasks |> Enum.map(&Task.await(&1, 10_000)) |> Enum.sort()
      assert results == Enum.to_list(1..n)

      # All permits should be released
      assert current(sem) == 0
    end
  end

  describe "child_spec" do
    test "starts under a supervisor" do
      name = :"sem_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.WeightedSemaphore, name: name, max: 5}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
      assert {:ok, :works} = Resiliency.WeightedSemaphore.acquire(name, fn -> :works end)
      Supervisor.stop(sup)
    end
  end

  # --- Helpers ---

  defp start_sem!(opts) do
    name = :"sem_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    start_supervised!({Resiliency.WeightedSemaphore, opts})
    name
  end

  defp current(sem) do
    :sys.get_state(sem).current
  end

  defp waiter_count(sem) do
    :queue.len(:sys.get_state(sem).waiters)
  end

  defp gate_new do
    {:ok, pid} = Agent.start_link(fn -> :closed end)
    pid
  end

  defp gate_open(gate) do
    Agent.update(gate, fn _ -> :open end)
  end

  defp gate_wait(gate) do
    wait_until(fn -> Agent.get(gate, & &1) == :open end)
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

  defp refute_done(task) do
    ref = task.ref
    refute_receive {^ref, _}, 0
  end

  defp start_agent!(initial) do
    {:ok, pid} = Agent.start_link(fn -> initial end)
    pid
  end
end
