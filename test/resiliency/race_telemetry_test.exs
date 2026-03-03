defmodule Resiliency.RaceTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-race-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :race, :run, :start],
      [:resiliency, :race, :run, :stop],
      [:resiliency, :race, :run, :exception]
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

  describe "successful race telemetry" do
    test "emits start and stop events with result :ok on success" do
      assert {:ok, :hello} = Resiliency.Race.run([fn -> :hello end, fn -> :world end])

      assert_receive {:telemetry, [:resiliency, :race, :run, :start], start_measurements,
                      start_metadata}

      assert %{system_time: system_time} = start_measurements
      assert is_integer(system_time)
      assert %{count: 2} = start_metadata

      assert_receive {:telemetry, [:resiliency, :race, :run, :stop], stop_measurements,
                      stop_metadata}

      assert %{duration: duration} = stop_measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{count: 2, result: :ok} = stop_metadata
    end
  end

  describe "failed race telemetry" do
    test "emits start and stop events with result :error when all fail" do
      assert {:error, :all_failed} =
               Resiliency.Race.run([fn -> raise "boom" end, fn -> raise "bang" end])

      assert_receive {:telemetry, [:resiliency, :race, :run, :start], _measurements, %{count: 2}}

      assert_receive {:telemetry, [:resiliency, :race, :run, :stop], %{duration: duration},
                      stop_metadata}

      assert duration >= 0
      assert %{count: 2, result: :error} = stop_metadata
    end
  end

  describe "duration measurement" do
    test "duration is non-negative in stop event" do
      assert {:ok, :done} = Resiliency.Race.run([fn -> :done end])

      assert_receive {:telemetry, [:resiliency, :race, :run, :stop], %{duration: duration}, _}
      assert is_integer(duration)
      assert duration >= 0
    end
  end
end
