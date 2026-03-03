defmodule Resiliency.BulkheadTest do
  use ExUnit.Case, async: true
  doctest Resiliency.Bulkhead

  describe "call/2 basic" do
    test "returns {:ok, result} on success" do
      bh = start_bulkhead!()
      assert {:ok, 42} = Resiliency.Bulkhead.call(bh, fn -> 42 end)
    end

    test "returns {:ok, result} preserving the raw return value" do
      bh = start_bulkhead!()
      assert {:ok, {:ok, "data"}} = Resiliency.Bulkhead.call(bh, fn -> {:ok, "data"} end)
    end

    test "catches raise and returns {:error, {exception, stacktrace}}" do
      bh = start_bulkhead!()

      assert {:error, {%RuntimeError{message: "boom"}, stacktrace}} =
               Resiliency.Bulkhead.call(bh, fn -> raise "boom" end)

      assert is_list(stacktrace)
    end

    test "catches exit and returns {:error, reason}" do
      bh = start_bulkhead!()
      assert {:error, :oops} = Resiliency.Bulkhead.call(bh, fn -> exit(:oops) end)
    end

    test "catches throw and returns {:error, {:nocatch, value}}" do
      bh = start_bulkhead!()

      assert {:error, {:nocatch, :thrown}} =
               Resiliency.Bulkhead.call(bh, fn -> throw(:thrown) end)
    end

    test "function runs in caller's process" do
      bh = start_bulkhead!()
      caller = self()

      {:ok, pid} = Resiliency.Bulkhead.call(bh, fn -> self() end)
      assert pid == caller
    end
  end

  describe "permit limiting" do
    test "allows up to max_concurrent" do
      bh = start_bulkhead!(max_concurrent: 3)
      gate = gate_new()

      # Start 3 concurrent calls
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn ->
              gate_wait(gate)
              :done
            end)
          end)
        end

      wait_until(fn -> current(bh) == 3 end)
      assert current(bh) == 3

      gate_open(gate)
      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == {:ok, :done}))
    end

    test "rejects when full with max_wait: 0" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 0)
      gate = gate_new()

      # Fill the bulkhead
      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Should be rejected immediately
      assert {:error, :bulkhead_full} = Resiliency.Bulkhead.call(bh, fn -> :never end)

      gate_open(gate)
      assert {:ok, :done} = Task.await(task)
    end

    test "permits freed after success" do
      bh = start_bulkhead!(max_concurrent: 1)
      assert {:ok, :first} = Resiliency.Bulkhead.call(bh, fn -> :first end)
      assert {:ok, :second} = Resiliency.Bulkhead.call(bh, fn -> :second end)
    end

    test "permits freed after raise" do
      bh = start_bulkhead!(max_concurrent: 1)
      assert {:error, _} = Resiliency.Bulkhead.call(bh, fn -> raise "boom" end)
      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
    end

    test "permits freed after exit" do
      bh = start_bulkhead!(max_concurrent: 1)
      assert {:error, :oops} = Resiliency.Bulkhead.call(bh, fn -> exit(:oops) end)
      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
    end

    test "permits freed after throw" do
      bh = start_bulkhead!(max_concurrent: 1)

      assert {:error, {:nocatch, :val}} =
               Resiliency.Bulkhead.call(bh, fn -> throw(:val) end)

      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
    end
  end

  describe "max_wait" do
    test "waits for permit when max_wait > 0" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()

      # Fill the bulkhead
      task1 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :first
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start a waiting call
      task2 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :second end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release the first call — second should proceed
      gate_open(gate)

      assert {:ok, :first} = Task.await(task1)
      assert {:ok, :second} = Task.await(task2)
    end

    test "rejects after timeout" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 50)
      gate = gate_new()

      # Fill the bulkhead
      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Should be rejected after timeout
      assert {:error, :bulkhead_full} = Resiliency.Bulkhead.call(bh, fn -> :never end)

      gate_open(gate)
      Task.await(task)
    end

    test "infinity waits forever" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: :infinity)
      gate = gate_new()

      # Fill the bulkhead
      task1 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :first
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start a waiting call — should block indefinitely
      task2 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :second end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Verify the waiter is still waiting
      refute_done(task2)

      # Release — waiter should proceed
      gate_open(gate)

      assert {:ok, :first} = Task.await(task1)
      assert {:ok, :second} = Task.await(task2)
    end

    test "per-call override" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 0)
      gate = gate_new()

      # Fill the bulkhead
      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :first
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Default max_wait: 0 would reject, but override to 5_000
      task2 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :second end, max_wait: 5_000)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      gate_open(gate)
      assert {:ok, :first} = Task.await(task)
      assert {:ok, :second} = Task.await(task2)
    end

    test "server default used when no per-call override" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()

      # Fill the bulkhead
      task1 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :first
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # No per-call override — should use server default of 5_000ms
      task2 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :second end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      gate_open(gate)
      assert {:ok, :first} = Task.await(task1)
      assert {:ok, :second} = Task.await(task2)
    end
  end

  describe "FIFO fairness" do
    test "waiters served in order" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()
      test_pid = self()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start waiters in order
      task_a =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, {:served, :a})
            :a
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      task_b =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, {:served, :b})
            :b
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 2 end)

      task_c =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, {:served, :c})
            :c
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 3 end)

      # Release — all should proceed in FIFO order
      gate_open(gate)

      Task.await(task_holder)
      Task.await(task_a)
      Task.await(task_b)
      Task.await(task_c)

      # Collect served order
      order =
        for _ <- 1..3 do
          receive do
            {:served, id} -> id
          after
            5_000 -> raise "timeout waiting for served message"
          end
        end

      assert order == [:a, :b, :c]
    end
  end

  describe "waiter cleanup on death" do
    test "waiter removed from queue when process dies" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: :infinity)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start a waiter, then kill it
      {pid, monitor_ref} =
        spawn_monitor(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :never end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :killed}, 5_000

      wait_until(fn -> waiter_count(bh) == 0 end)

      gate_open(gate)
      Task.await(task_holder)
    end

    test "dead waiter doesn't steal permits" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: :infinity)
      gate = gate_new()
      test_pid = self()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start waiter A (will die), then waiter B (will live)
      {pid_a, ref_a} =
        spawn_monitor(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :a end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      task_b =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, :b_served)
            :b
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 2 end)

      # Kill waiter A
      Process.exit(pid_a, :kill)
      assert_receive {:DOWN, ^ref_a, :process, ^pid_a, :killed}, 5_000

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release holder — waiter B should get the permit, not dead A
      gate_open(gate)
      Task.await(task_holder)

      assert_receive :b_served, 5_000
      assert {:ok, :b} = Task.await(task_b)
    end

    test "active permit holder death releases permit" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)

      # Start a call that will die
      {pid, ref} =
        spawn_monitor(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            Process.sleep(:infinity)
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Kill the permit holder
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      # Permit should be released
      wait_until(fn -> current(bh) == 0 end)

      # New call should succeed
      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
    end
  end

  describe "timer cleanup" do
    test "timer cancelled when waiter granted" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 60_000)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start a waiter with a long timeout
      task_waiter =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :waiter end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release — waiter should be granted, timer should be cancelled
      gate_open(gate)

      assert {:ok, :holder} = Task.await(task_holder)
      assert {:ok, :waiter} = Task.await(task_waiter)

      # Wait a bit — no stale timeout should fire
      Process.sleep(50)
      assert current(bh) == 0
    end

    test "stale timeout ignored" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Manually send a stale timeout message
      send(Process.whereis(bh), {:waiter_timeout, make_ref()})

      # Should still work fine
      gate_open(gate)
      assert {:ok, :holder} = Task.await(task_holder)
      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
    end
  end

  describe "callbacks" do
    test "on_call_permitted fires when call is permitted" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 2,
          on_call_permitted: fn name -> send(test_pid, {:permitted, name}) end
        )

      Resiliency.Bulkhead.call(bh, fn -> :ok end)
      assert_received {:permitted, ^bh}
    end

    test "on_call_rejected fires when call is rejected" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: 0,
          on_call_rejected: fn name -> send(test_pid, {:rejected, name}) end
        )

      gate = gate_new()

      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      Resiliency.Bulkhead.call(bh, fn -> :never end)
      assert_received {:rejected, ^bh}

      gate_open(gate)
      Task.await(task)
    end

    test "on_call_finished fires when call finishes" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 2,
          on_call_finished: fn name -> send(test_pid, {:finished, name}) end
        )

      Resiliency.Bulkhead.call(bh, fn -> :ok end)

      # The cast is async, so flush with a get_stats call
      Resiliency.Bulkhead.get_stats(bh)
      assert_received {:finished, ^bh}
    end

    test "on_call_permitted fires for granted waiters" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: 5_000,
          on_call_permitted: fn name -> send(test_pid, {:permitted, name}) end
        )

      gate = gate_new()

      task1 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :first
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)
      assert_received {:permitted, ^bh}

      task2 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :second end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      gate_open(gate)

      Task.await(task1)
      Task.await(task2)

      # Flush
      Resiliency.Bulkhead.get_stats(bh)
      assert_received {:permitted, ^bh}
    end

    test "on_call_rejected fires on timeout rejection" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: 50,
          on_call_rejected: fn name -> send(test_pid, {:rejected, name}) end
        )

      gate = gate_new()

      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      Resiliency.Bulkhead.call(bh, fn -> :never end)
      assert_received {:rejected, ^bh}

      gate_open(gate)
      Task.await(task)
    end

    test "callback crash doesn't crash GenServer" do
      bh =
        start_bulkhead!(
          max_concurrent: 2,
          on_call_permitted: fn _name -> raise "callback boom" end
        )

      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
      assert Process.alive?(Process.whereis(bh))
    end
  end

  describe "get_stats/1" do
    test "initial stats" do
      bh = start_bulkhead!(max_concurrent: 5)
      stats = Resiliency.Bulkhead.get_stats(bh)

      assert stats.max_concurrent == 5
      assert stats.current == 0
      assert stats.available == 5
      assert stats.waiting == 0
    end

    test "reflects active permits and waiters" do
      bh = start_bulkhead!(max_concurrent: 2, max_wait: 5_000)
      gate = gate_new()

      # Fill both slots
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn ->
              gate_wait(gate)
              :done
            end)
          end)
        end

      wait_until(fn -> current(bh) == 2 end)

      # Start a waiter
      task_waiter =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :waiter end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      stats = Resiliency.Bulkhead.get_stats(bh)
      assert stats.current == 2
      assert stats.available == 0
      assert stats.waiting == 1

      gate_open(gate)
      Enum.each(tasks, &Task.await/1)
      Task.await(task_waiter)
    end
  end

  describe "reset/1" do
    test "clears current and queue" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: :infinity)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start waiters
      waiter_tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn -> :waiter end)
          end)
        end

      wait_until(fn -> waiter_count(bh) == 3 end)

      # Reset — should reject all waiters and clear current
      :ok = Resiliency.Bulkhead.reset(bh)

      stats = Resiliency.Bulkhead.get_stats(bh)
      assert stats.current == 0
      assert stats.waiting == 0

      # Waiters should all get :bulkhead_full
      results = Enum.map(waiter_tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == {:error, :bulkhead_full}))

      # New calls should work
      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)

      # Clean up the holder
      gate_open(gate)
      Task.await(task_holder)
    end
  end

  describe "child_spec" do
    test "starts under supervisor" do
      name = :"bh_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.Bulkhead, name: name, max_concurrent: 5}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, 42} = Resiliency.Bulkhead.call(name, fn -> 42 end)

      Supervisor.stop(sup)
    end
  end

  describe "validation" do
    test "missing max_concurrent raises" do
      assert_raise KeyError, fn ->
        Resiliency.Bulkhead.start_link(name: :"bh_invalid_#{System.unique_integer([:positive])}")
      end
    end

    test "invalid max_concurrent raises ArgumentError" do
      assert_raise ArgumentError, ~r/max_concurrent/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: -1
        )
      end

      assert_raise ArgumentError, ~r/max_concurrent/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: "not_a_number"
        )
      end
    end

    test "max_concurrent: 0 is valid and rejects all calls" do
      bh = start_bulkhead!(max_concurrent: 0)
      assert {:error, :bulkhead_full} = Resiliency.Bulkhead.call(bh, fn -> :unreachable end)
    end

    test "invalid max_wait raises ArgumentError" do
      assert_raise ArgumentError, ~r/max_wait/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: 5,
          max_wait: -1
        )
      end

      assert_raise ArgumentError, ~r/max_wait/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: 5,
          max_wait: "not_valid"
        )
      end
    end

    test "max_wait: 0 is valid" do
      name = :"bh_valid_#{System.unique_integer([:positive])}"
      {:ok, pid} = Resiliency.Bulkhead.start_link(name: name, max_concurrent: 5, max_wait: 0)
      GenServer.stop(pid)
    end

    test "max_wait: :infinity is valid" do
      name = :"bh_valid_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Resiliency.Bulkhead.start_link(name: name, max_concurrent: 5, max_wait: :infinity)

      GenServer.stop(pid)
    end

    test "invalid callbacks raise ArgumentError" do
      assert_raise ArgumentError, ~r/on_call_permitted/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: 5,
          on_call_permitted: :not_a_function
        )
      end

      assert_raise ArgumentError, ~r/on_call_rejected/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: 5,
          on_call_rejected: "not_a_function"
        )
      end

      assert_raise ArgumentError, ~r/on_call_finished/, fn ->
        Resiliency.Bulkhead.start_link(
          name: :"bh_invalid_#{System.unique_integer([:positive])}",
          max_concurrent: 5,
          on_call_finished: fn _a, _b -> :wrong_arity end
        )
      end
    end
  end

  describe "edge cases" do
    test "per-call max_wait: 0 override is respected (not treated as falsy)" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()

      # Fill the bulkhead
      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Per-call max_wait: 0 should reject immediately, not use server default of 5_000
      assert {:error, :bulkhead_full} =
               Resiliency.Bulkhead.call(bh, fn -> :never end, max_wait: 0)

      gate_open(gate)
      Task.await(task)
    end

    test "max_concurrent: 0 with max_wait > 0 rejects immediately (no infinite queue)" do
      bh = start_bulkhead!(max_concurrent: 0, max_wait: 5_000)
      assert {:error, :bulkhead_full} = Resiliency.Bulkhead.call(bh, fn -> :unreachable end)
    end

    test "max_concurrent: 0 with max_wait: :infinity rejects immediately" do
      bh = start_bulkhead!(max_concurrent: 0, max_wait: :infinity)
      assert {:error, :bulkhead_full} = Resiliency.Bulkhead.call(bh, fn -> :unreachable end)
    end

    test "double release of same permit is harmless" do
      bh = start_bulkhead!(max_concurrent: 1)

      # Manually acquire a permit
      {:ok, ref} = GenServer.call(Process.whereis(bh), {:acquire, nil}, :infinity)

      # Release it twice
      GenServer.cast(Process.whereis(bh), {:release_permit, ref})
      GenServer.cast(Process.whereis(bh), {:release_permit, ref})

      # Flush the casts
      _ = Resiliency.Bulkhead.get_stats(bh)

      # current should be 0, not -1
      assert current(bh) == 0
    end

    test "reset while active holder still running doesn't corrupt state" do
      bh = start_bulkhead!(max_concurrent: 1)
      gate = gate_new()

      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Reset clears state — the holder's GenServer.cast release will be stale
      :ok = Resiliency.Bulkhead.reset(bh)
      assert current(bh) == 0

      # Let the holder finish — it will cast release_permit with the old ref
      gate_open(gate)
      {:ok, :done} = Task.await(task)

      # Flush the stale cast
      _ = Resiliency.Bulkhead.get_stats(bh)

      # current should still be 0, not -1
      assert current(bh) == 0
    end

    test "stale DOWN message from demonitored process is harmless" do
      bh = start_bulkhead!()
      pid = Process.whereis(bh)

      # Send a fake DOWN for a ref that doesn't exist
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})

      # Should still work
      assert {:ok, 42} = Resiliency.Bulkhead.call(bh, fn -> 42 end)
    end

    test "waiter granted just before its process dies — permit self-heals" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: :infinity)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Start a waiter that will receive the permit then immediately die
      {waiter_pid, waiter_ref} =
        spawn_monitor(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            # This process will be killed while running the function
            Process.sleep(:infinity)
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release the holder — waiter gets the permit
      gate_open(gate)
      {:ok, :holder} = Task.await(task_holder)

      # Wait for waiter to get the permit
      wait_until(fn -> current(bh) == 1 and waiter_count(bh) == 0 end)

      # Now kill the waiter
      Process.exit(waiter_pid, :kill)
      assert_receive {:DOWN, ^waiter_ref, :process, ^waiter_pid, :killed}, 5_000

      # Permit should self-heal — released by DOWN monitor
      wait_until(fn -> current(bh) == 0 end)

      # New call should work
      assert {:ok, :ok} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
    end
  end

  describe "edge cases: second sweep" do
    test "reset fires on_call_rejected for each queued waiter" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: :infinity,
          on_call_rejected: fn name -> send(test_pid, {:rejected, name}) end
        )

      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Queue 3 waiters
      waiter_tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn -> :waiter end)
          end)
        end

      wait_until(fn -> waiter_count(bh) == 3 end)

      # Reset — should fire on_call_rejected for each waiter
      :ok = Resiliency.Bulkhead.reset(bh)

      for _ <- 1..3 do
        assert_receive {:rejected, ^bh}, 1_000
      end

      # Waiters get rejection
      results = Enum.map(waiter_tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == {:error, :bulkhead_full}))

      gate_open(gate)
      Task.await(task_holder)
    end

    test "capacity available but queue non-empty still enforces FIFO" do
      # With max_concurrent: 2, fill 2 slots, queue 1 waiter, release 1 slot.
      # The waiter should get the slot, not a new caller.
      bh = start_bulkhead!(max_concurrent: 2, max_wait: 5_000)
      gate1 = gate_new()
      gate2 = gate_new()
      test_pid = self()

      # Fill both slots
      task_a =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate1)
            :a
          end)
        end)

      task_b =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate2)
            :b
          end)
        end)

      wait_until(fn -> current(bh) == 2 end)

      # Queue a waiter
      task_waiter =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, :waiter_served)
            :waiter
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release slot A — waiter should get it (FIFO), not a fresh caller
      gate_open(gate1)
      {:ok, :a} = Task.await(task_a)

      assert_receive :waiter_served, 5_000
      assert {:ok, :waiter} = Task.await(task_waiter)

      gate_open(gate2)
      Task.await(task_b)
    end

    test "multiple waiters timeout in order" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 50)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Queue 3 waiters — all should timeout
      waiter_tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn -> :never end)
          end)
        end

      # All should be rejected after timeout
      results = Enum.map(waiter_tasks, &Task.await(&1, 5_000))
      assert Enum.all?(results, &(&1 == {:error, :bulkhead_full}))

      gate_open(gate)
      Task.await(task_holder)
    end

    test "release_permit during waiter queue grants to front waiter not back" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()
      test_pid = self()

      # Fill
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Queue A then B
      task_a =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, {:order, :a})
            :a
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      task_b =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            send(test_pid, {:order, :b})
            :b
          end)
        end)

      wait_until(fn -> waiter_count(bh) == 2 end)

      # Release — A should be served first
      gate_open(gate)
      Task.await(task_holder)
      Task.await(task_a)
      Task.await(task_b)

      first =
        receive do
          {:order, id} -> id
        after
          1_000 -> :timeout
        end

      assert first == :a
    end

    test "callback crash during waiter grant doesn't prevent grant" do
      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: 5_000,
          on_call_permitted: fn _name -> raise "boom in callback" end
        )

      gate = gate_new()

      # Fill
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Queue a waiter
      task_waiter =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :waiter end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release — callback will crash but waiter should still be granted
      gate_open(gate)
      Task.await(task_holder)
      assert {:ok, :waiter} = Task.await(task_waiter)
    end

    test "callback crash during on_call_finished doesn't prevent next waiter grant" do
      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: 5_000,
          on_call_finished: fn _name -> raise "boom in finished" end
        )

      gate = gate_new()

      # Fill
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Queue a waiter
      task_waiter =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :waiter end)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      # Release — on_call_finished crashes, but grant_next_waiter should still run
      gate_open(gate)
      Task.await(task_holder)
      assert {:ok, :waiter} = Task.await(task_waiter)
    end

    test "callback crash during on_call_rejected doesn't crash reset" do
      bh =
        start_bulkhead!(
          max_concurrent: 1,
          max_wait: :infinity,
          on_call_rejected: fn _name -> raise "boom in rejected" end
        )

      gate = gate_new()

      # Fill
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Queue waiters
      waiter_tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn -> :waiter end)
          end)
        end

      wait_until(fn -> waiter_count(bh) == 2 end)

      # Reset — on_call_rejected crashes for each waiter, but reset should complete
      :ok = Resiliency.Bulkhead.reset(bh)
      assert Process.alive?(Process.whereis(bh))

      results = Enum.map(waiter_tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == {:error, :bulkhead_full}))

      gate_open(gate)
      Task.await(task_holder)
    end

    test "rapid fill-and-drain doesn't leak permits" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)

      # Rapidly acquire and release 50 times sequentially
      for i <- 1..50 do
        assert {:ok, ^i} = Resiliency.Bulkhead.call(bh, fn -> i end)
      end

      assert current(bh) == 0
      assert waiter_count(bh) == 0
    end

    test "on_call_finished fires when permit holder dies" do
      test_pid = self()

      bh =
        start_bulkhead!(
          max_concurrent: 1,
          on_call_finished: fn name -> send(test_pid, {:finished, name}) end
        )

      {pid, ref} =
        spawn_monitor(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            Process.sleep(:infinity)
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000

      wait_until(fn -> current(bh) == 0 end)
      assert_received {:finished, ^bh}
    end
  end

  describe "edge cases: third sweep" do
    test "per-call max_wait: -1 raises ArgumentError (not crash GenServer)" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 5_000)
      gate = gate_new()

      # Fill the bulkhead so we actually reach the enqueue path
      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Invalid per-call max_wait should raise on the caller, not crash the server
      assert_raise ArgumentError, ~r/max_wait/, fn ->
        Resiliency.Bulkhead.call(bh, fn -> :never end, max_wait: -1)
      end

      # Server is still alive
      assert Process.alive?(Process.whereis(bh))

      gate_open(gate)
      Task.await(task)
    end

    test "per-call max_wait: :not_a_number raises ArgumentError" do
      bh = start_bulkhead!(max_concurrent: 5)

      assert_raise ArgumentError, ~r/max_wait/, fn ->
        Resiliency.Bulkhead.call(bh, fn -> :never end, max_wait: "500")
      end
    end

    test "per-call max_wait: :infinity is valid" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 0)
      gate = gate_new()

      # Fill the bulkhead
      task =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn ->
            gate_wait(gate)
            :done
          end)
        end)

      wait_until(fn -> current(bh) == 1 end)

      # Per-call :infinity override should queue instead of rejecting
      task2 =
        Task.async(fn ->
          Resiliency.Bulkhead.call(bh, fn -> :second end, max_wait: :infinity)
        end)

      wait_until(fn -> waiter_count(bh) == 1 end)

      gate_open(gate)
      assert {:ok, :done} = Task.await(task)
      assert {:ok, :second} = Task.await(task2)
    end

    test "recursive call deadlocks with max_concurrent: 1 and max_wait: 0" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 0)

      # Outer call holds the permit, inner call is rejected
      assert {:ok, {:error, :bulkhead_full}} =
               Resiliency.Bulkhead.call(bh, fn ->
                 Resiliency.Bulkhead.call(bh, fn -> :inner end)
               end)
    end

    test "concurrent calls from same process via Task" do
      # Verify that Task-spawned calls from the same parent work correctly
      bh = start_bulkhead!(max_concurrent: 2, max_wait: 5_000)

      results =
        1..2
        |> Enum.map(fn i ->
          Task.async(fn ->
            Resiliency.Bulkhead.call(bh, fn -> i end)
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.sort(results) == [{:ok, 1}, {:ok, 2}]
    end

    test "GenServer death while caller is waiting in queue" do
      name = :"bh_death_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.Bulkhead, name: name, max_concurrent: 1, max_wait: :infinity}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
      gate = gate_new()

      # Fill the bulkhead
      task_holder =
        Task.async(fn ->
          Resiliency.Bulkhead.call(name, fn ->
            gate_wait(gate)
            :holder
          end)
        end)

      wait_until(fn -> current(name) == 1 end)

      # Start a waiter
      task_waiter =
        Task.async(fn ->
          try do
            Resiliency.Bulkhead.call(name, fn -> :waiter end)
          catch
            :exit, _ -> :server_died
          end
        end)

      wait_until(fn -> waiter_count(name) == 1 end)

      # Kill the GenServer — waiter should get an exit
      pid = Process.whereis(name)
      Process.exit(pid, :kill)

      result = Task.await(task_waiter, 5_000)
      assert result == :server_died

      gate_open(gate)

      try do
        Task.await(task_holder, 1_000)
      catch
        :exit, _ -> :ok
      end

      Supervisor.stop(sup)
    end

    test "max_concurrent: 1 with many rapid concurrent callers" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 10_000)
      counter = :counters.new(1, [:atomics])

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            {:ok, _} =
              Resiliency.Bulkhead.call(bh, fn ->
                # Verify at most 1 is running concurrently
                cur = :counters.add(counter, 1, 1)

                if :counters.get(counter, 1) > 1 do
                  raise "concurrent violation!"
                end

                Process.sleep(1)
                :counters.sub(counter, 1, 1)
                cur
              end)
          end)
        end

      Enum.each(tasks, &Task.await(&1, 30_000))
      assert current(bh) == 0
    end

    test "calling with PID instead of registered name works" do
      bh = start_bulkhead!(max_concurrent: 2)
      pid = Process.whereis(bh)

      assert {:ok, :ok} = Resiliency.Bulkhead.call(pid, fn -> :ok end)
    end

    test "max_concurrent: 1 sequential calls don't accumulate monitors" do
      bh = start_bulkhead!(max_concurrent: 1)

      # Run 10 sequential calls
      for _ <- 1..10 do
        {:ok, _} = Resiliency.Bulkhead.call(bh, fn -> :ok end)
      end

      # After all calls, state should be clean
      stats = Resiliency.Bulkhead.get_stats(bh)
      assert stats.current == 0
      assert stats.waiting == 0

      # Verify via :sys.get_state that active_monitors is empty
      state = :sys.get_state(Process.whereis(bh))
      assert map_size(state.active_monitors) == 0
    end
  end

  describe "stress test" do
    test "100 concurrent callers all complete" do
      bh = start_bulkhead!(max_concurrent: 10, max_wait: 30_000)

      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            {:ok, result} = Resiliency.Bulkhead.call(bh, fn -> i * 2 end)
            result
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 30_000))
      assert length(results) == 100
      assert Enum.sort(results) == Enum.map(1..100, &(&1 * 2))

      stats = Resiliency.Bulkhead.get_stats(bh)
      assert stats.current == 0
      assert stats.waiting == 0
    end
  end

  describe "unknown messages" do
    test "unknown info messages are silently ignored" do
      bh = start_bulkhead!()

      send(Process.whereis(bh), :unknown_message)
      send(Process.whereis(bh), {:random, :tuple})

      # GenServer should still work
      assert {:ok, 42} = Resiliency.Bulkhead.call(bh, fn -> 42 end)
    end
  end

  describe "supervisor restart recovery" do
    test "bulkhead restarts clean after crash" do
      name = :"bh_sup_#{System.unique_integer([:positive])}"

      children = [
        {Resiliency.Bulkhead, name: name, max_concurrent: 5}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

      # Use all permits
      gate = gate_new()

      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Resiliency.Bulkhead.call(name, fn ->
              gate_wait(gate)
              :done
            end)
          end)
        end

      wait_until(fn -> current(name) == 5 end)

      # Kill the GenServer
      pid = Process.whereis(name)
      Process.exit(pid, :kill)

      # Wait for restart
      wait_until(fn -> Process.whereis(name) != nil and Process.whereis(name) != pid end)

      # Should restart clean
      stats = Resiliency.Bulkhead.get_stats(name)
      assert stats.current == 0
      assert stats.waiting == 0

      # New calls should work
      assert {:ok, :ok} = Resiliency.Bulkhead.call(name, fn -> :ok end)

      gate_open(gate)

      # The old tasks will fail since the GenServer was killed
      for task <- tasks do
        try do
          Task.await(task, 1_000)
        catch
          :exit, _ -> :ok
        end
      end

      Supervisor.stop(sup)
    end
  end

  # --- Helpers ---

  defp start_bulkhead!(opts \\ []) do
    name = :"bh_#{System.unique_integer([:positive])}"
    opts = Keyword.put_new(opts, :max_concurrent, 5)
    opts = Keyword.put(opts, :name, name)
    start_supervised!({Resiliency.Bulkhead, opts})
    name
  end

  defp gate_new do
    name = :"gate_#{System.unique_integer([:positive])}"
    :ets.new(name, [:set, :public, :named_table])
    :ets.insert(name, {:open, false})
    name
  end

  defp gate_open(gate) do
    :ets.insert(gate, {:open, true})
  end

  defp gate_wait(gate) do
    wait_until(fn ->
      case :ets.lookup(gate, :open) do
        [{:open, true}] -> true
        _ -> false
      end
    end)
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

      Process.sleep(5)
      do_wait_until(fun, deadline)
    end
  end

  defp refute_done(task) do
    ref = task.ref
    refute_receive {^ref, _}, 100
  end

  defp current(bh) do
    Resiliency.Bulkhead.get_stats(bh).current
  end

  defp waiter_count(bh) do
    Resiliency.Bulkhead.get_stats(bh).waiting
  end
end
