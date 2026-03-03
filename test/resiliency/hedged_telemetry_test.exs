defmodule Resiliency.HedgedTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-hedged-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :hedged, :run, :start],
      [:resiliency, :hedged, :run, :stop],
      [:resiliency, :hedged, :hedge]
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

  describe "stateless run/2 telemetry" do
    test "emits start and stop events on success" do
      assert {:ok, 42} = Resiliency.Hedged.run(fn -> {:ok, 42} end, max_requests: 1)

      assert_receive {:telemetry, [:resiliency, :hedged, :run, :start], start_measurements,
                      start_metadata}

      assert %{system_time: system_time} = start_measurements
      assert is_integer(system_time)
      assert %{mode: :stateless} = start_metadata

      assert_receive {:telemetry, [:resiliency, :hedged, :run, :stop], stop_measurements,
                      stop_metadata}

      assert %{duration: duration} = stop_measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{mode: :stateless, result: :ok, dispatched: 1, hedged: false} = stop_metadata
    end

    test "emits start and stop events on error" do
      assert {:error, :boom} =
               Resiliency.Hedged.run(fn -> {:error, :boom} end, max_requests: 1)

      assert_receive {:telemetry, [:resiliency, :hedged, :run, :start], _measurements,
                      %{mode: :stateless}}

      assert_receive {:telemetry, [:resiliency, :hedged, :run, :stop], %{duration: duration},
                      stop_metadata}

      assert duration >= 0
      assert %{mode: :stateless, result: :error, dispatched: 1, hedged: false} = stop_metadata
    end
  end

  describe "hedge point event" do
    test "fires when hedge is dispatched" do
      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          Process.sleep(200)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast} =
               Resiliency.Hedged.run(fun, delay: 0, max_requests: 2, timeout: 5_000)

      assert_receive {:telemetry, [:resiliency, :hedged, :hedge], %{}, %{attempt: 2}}

      assert_receive {:telemetry, [:resiliency, :hedged, :run, :stop], _measurements,
                      %{dispatched: 2, hedged: true}}
    end
  end

  describe "on_hedge callback preservation" do
    test "on_hedge callback still fires alongside telemetry" do
      callback_agent = start_supervised!({Agent, fn -> [] end})

      counter = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if n == 1 do
          Process.sleep(200)
          {:ok, :slow}
        else
          {:ok, :fast}
        end
      end

      assert {:ok, :fast} =
               Resiliency.Hedged.run(fun,
                 delay: 0,
                 max_requests: 2,
                 timeout: 5_000,
                 on_hedge: fn attempt ->
                   Agent.update(callback_agent, &[attempt | &1])
                 end
               )

      # Telemetry hedge event should have fired
      assert_receive {:telemetry, [:resiliency, :hedged, :hedge], %{}, %{attempt: 2}}

      # User callback should also have been invoked
      callback_attempts = Agent.get(callback_agent, & &1)
      assert 2 in callback_attempts
    end
  end

  describe "duration measurement" do
    test "duration is non-negative in stop event" do
      assert {:ok, :done} = Resiliency.Hedged.run(fn -> {:ok, :done} end, max_requests: 1)

      assert_receive {:telemetry, [:resiliency, :hedged, :run, :stop], %{duration: duration}, _}
      assert is_integer(duration)
      assert duration >= 0
    end
  end
end
