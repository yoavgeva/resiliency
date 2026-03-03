defmodule Resiliency.FirstOkTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-first-ok-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :first_ok, :run, :start],
      [:resiliency, :first_ok, :run, :stop],
      [:resiliency, :first_ok, :run, :exception]
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

  describe "first success telemetry" do
    test "emits start and stop events with result :ok and attempts 1 on first success" do
      assert {:ok, :hello} =
               Resiliency.FirstOk.run([fn -> :hello end, fn -> :world end])

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :start], start_measurements,
                      start_metadata}

      assert %{system_time: system_time} = start_measurements
      assert is_integer(system_time)
      assert %{count: 2} = start_metadata

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :stop], stop_measurements,
                      stop_metadata}

      assert %{duration: duration} = stop_measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{count: 2, result: :ok, attempts: 1} = stop_metadata
    end
  end

  describe "fallback success telemetry" do
    test "emits start and stop events with result :ok and attempts 2 on fallback success" do
      assert {:ok, :backup} =
               Resiliency.FirstOk.run([
                 fn -> {:error, :miss} end,
                 fn -> :backup end
               ])

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :start], _measurements,
                      %{count: 2}}

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :stop], %{duration: duration},
                      stop_metadata}

      assert duration >= 0
      assert %{count: 2, result: :ok, attempts: 2} = stop_metadata
    end
  end

  describe "all failed telemetry" do
    test "emits start and stop events with result :error and attempts equal to count" do
      assert {:error, :all_failed} =
               Resiliency.FirstOk.run([
                 fn -> raise "boom" end,
                 fn -> {:error, :nope} end,
                 fn -> raise "bang" end
               ])

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :start], _measurements,
                      %{count: 3}}

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :stop], %{duration: duration},
                      stop_metadata}

      assert duration >= 0
      assert %{count: 3, result: :error, attempts: 3} = stop_metadata
    end
  end

  describe "duration measurement" do
    test "duration is non-negative in stop event" do
      assert {:ok, :done} = Resiliency.FirstOk.run([fn -> :done end])

      assert_receive {:telemetry, [:resiliency, :first_ok, :run, :stop], %{duration: duration}, _}
      assert is_integer(duration)
      assert duration >= 0
    end
  end
end
