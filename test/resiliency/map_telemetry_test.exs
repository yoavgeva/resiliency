defmodule Resiliency.MapTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-map-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :map, :run, :start],
      [:resiliency, :map, :run, :stop],
      [:resiliency, :map, :run, :exception]
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

  describe "successful map telemetry" do
    test "emits start and stop events with result :ok, count, and max_concurrency on success" do
      assert {:ok, [2, 4, 6]} =
               Resiliency.Map.run([1, 2, 3], fn x -> x * 2 end, max_concurrency: 2)

      assert_receive {:telemetry, [:resiliency, :map, :run, :start], start_measurements,
                      start_metadata}

      assert %{system_time: system_time} = start_measurements
      assert is_integer(system_time)
      assert %{count: 3, max_concurrency: 2} = start_metadata

      assert_receive {:telemetry, [:resiliency, :map, :run, :stop], stop_measurements,
                      stop_metadata}

      assert %{duration: duration} = stop_measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{count: 3, max_concurrency: 2, result: :ok} = stop_metadata
    end
  end

  describe "failed map telemetry" do
    test "emits start and stop events with result :error on failure" do
      assert {:error, _reason} =
               Resiliency.Map.run([1, 2, 3], fn _ -> raise "boom" end, max_concurrency: 2)

      assert_receive {:telemetry, [:resiliency, :map, :run, :start], _measurements,
                      %{count: 3, max_concurrency: 2}}

      assert_receive {:telemetry, [:resiliency, :map, :run, :stop], %{duration: duration},
                      stop_metadata}

      assert duration >= 0
      assert %{count: 3, max_concurrency: 2, result: :error} = stop_metadata
    end
  end

  describe "duration measurement" do
    test "duration is non-negative in stop event" do
      assert {:ok, [1]} = Resiliency.Map.run([1], fn x -> x end, max_concurrency: 1)

      assert_receive {:telemetry, [:resiliency, :map, :run, :stop], %{duration: duration}, _}
      assert is_integer(duration)
      assert duration >= 0
    end
  end
end
