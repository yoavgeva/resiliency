defmodule Resiliency.WeightedSemaphoreTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-sem-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :semaphore, :acquire, :start],
      [:resiliency, :semaphore, :acquire, :stop],
      [:resiliency, :semaphore, :acquire, :rejected]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "acquire telemetry" do
    test "emits start and stop events on success" do
      sem = start_sem!(max: 5)

      assert {:ok, 42} = Resiliency.WeightedSemaphore.acquire(sem, 2, fn -> 42 end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], %{system_time: _},
                      %{name: ^sem, weight: 2}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, %{name: ^sem, weight: 2, result: :ok}}

      assert duration >= 0
    end

    test "emits start and stop events on function error with result :error" do
      sem = start_sem!(max: 5)

      assert {:error, _} = Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> raise "boom" end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], %{system_time: _},
                      %{name: ^sem, weight: 1}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, %{name: ^sem, weight: 1, result: :error}}

      assert duration >= 0
    end

    test "emits start, rejected, and stop events when weight exceeds max" do
      sem = start_sem!(max: 5)

      assert {:error, :weight_exceeds_max} =
               Resiliency.WeightedSemaphore.acquire(sem, 6, fn -> :never end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], %{system_time: _},
                      %{name: ^sem, weight: 6}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :rejected], %{},
                      %{name: ^sem, weight: 6}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, %{name: ^sem, weight: 6, result: :error}}

      assert duration >= 0
    end
  end

  describe "try_acquire telemetry" do
    test "emits start and stop events on success" do
      sem = start_sem!(max: 5)

      assert {:ok, :done} = Resiliency.WeightedSemaphore.try_acquire(sem, 1, fn -> :done end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], %{system_time: _},
                      %{name: ^sem, weight: 1}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, %{name: ^sem, weight: 1, result: :ok}}

      assert duration >= 0
    end

    test "emits start, rejected, and stop events when rejected" do
      sem = start_sem!(max: 1)
      gate = gate_new()

      _holder =
        Task.async(fn ->
          Resiliency.WeightedSemaphore.acquire(sem, 1, fn ->
            gate_wait(gate)
          end)
        end)

      wait_until(fn -> current(sem) == 1 end)

      assert :rejected = Resiliency.WeightedSemaphore.try_acquire(sem, 1, fn -> :never end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], %{system_time: _},
                      %{name: ^sem, weight: 1}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :rejected], %{},
                      %{name: ^sem, weight: 1}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, %{name: ^sem, weight: 1, result: :rejected}}

      assert duration >= 0

      gate_open(gate)
    end

    test "emits start, rejected, and stop events when weight exceeds max" do
      sem = start_sem!(max: 5)

      assert {:error, :weight_exceeds_max} =
               Resiliency.WeightedSemaphore.try_acquire(sem, 999, fn -> :never end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], %{system_time: _},
                      %{name: ^sem, weight: 999}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :rejected], %{},
                      %{name: ^sem, weight: 999}}

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, %{name: ^sem, weight: 999, result: :error}}

      assert duration >= 0
    end
  end

  describe "metadata" do
    test "start event includes name and weight" do
      sem = start_sem!(max: 10)

      Resiliency.WeightedSemaphore.acquire(sem, 3, fn -> :ok end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start], _measurements,
                      metadata}

      assert metadata.name == sem
      assert metadata.weight == 3
    end

    test "stop event includes name, weight, and result" do
      sem = start_sem!(max: 10)

      Resiliency.WeightedSemaphore.acquire(sem, 5, fn -> :ok end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop], _measurements,
                      metadata}

      assert metadata.name == sem
      assert metadata.weight == 5
      assert metadata.result == :ok
    end
  end

  describe "measurements" do
    test "start event has system_time" do
      sem = start_sem!(max: 5)

      Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :ok end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :start],
                      %{system_time: system_time}, _metadata}

      assert is_integer(system_time)
      assert system_time > 0
    end

    test "stop event has non-negative duration" do
      sem = start_sem!(max: 5)

      Resiliency.WeightedSemaphore.acquire(sem, 1, fn -> :ok end)

      assert_receive {:telemetry, [:resiliency, :semaphore, :acquire, :stop],
                      %{duration: duration}, _metadata}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  # --- Helpers ---

  defp start_sem!(opts) do
    name = :"sem_tel_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    start_supervised!({Resiliency.WeightedSemaphore, opts})
    name
  end

  defp current(sem) do
    :sys.get_state(sem).current
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
end
