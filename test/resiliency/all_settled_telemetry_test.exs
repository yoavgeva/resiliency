defmodule Resiliency.AllSettledTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-all-settled-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :all_settled, :run, :start],
      [:resiliency, :all_settled, :run, :stop],
      [:resiliency, :all_settled, :run, :exception]
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

  describe "all success telemetry" do
    test "emits start and stop events with correct ok and error counts on all success" do
      assert [{:ok, 1}, {:ok, 2}, {:ok, 3}] =
               Resiliency.AllSettled.run([fn -> 1 end, fn -> 2 end, fn -> 3 end])

      assert_receive {:telemetry, [:resiliency, :all_settled, :run, :start], start_measurements,
                      start_metadata}

      assert %{system_time: system_time} = start_measurements
      assert is_integer(system_time)
      assert %{count: 3} = start_metadata

      assert_receive {:telemetry, [:resiliency, :all_settled, :run, :stop], stop_measurements,
                      stop_metadata}

      assert %{duration: duration} = stop_measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{count: 3, ok_count: 3, error_count: 0} = stop_metadata
    end
  end

  describe "mixed results telemetry" do
    test "emits start and stop events with correct ok and error counts on mixed results" do
      results =
        Resiliency.AllSettled.run([
          fn -> 1 end,
          fn -> raise "boom" end,
          fn -> 3 end
        ])

      assert [{:ok, 1}, {:error, _}, {:ok, 3}] = results

      assert_receive {:telemetry, [:resiliency, :all_settled, :run, :start], _measurements,
                      %{count: 3}}

      assert_receive {:telemetry, [:resiliency, :all_settled, :run, :stop], %{duration: duration},
                      stop_metadata}

      assert duration >= 0
      assert %{count: 3, ok_count: 2, error_count: 1} = stop_metadata
    end
  end

  describe "duration measurement" do
    test "duration is non-negative in stop event" do
      assert [{:ok, :done}] = Resiliency.AllSettled.run([fn -> :done end])

      assert_receive {:telemetry, [:resiliency, :all_settled, :run, :stop], %{duration: duration},
                      _}

      assert is_integer(duration)
      assert duration >= 0
    end
  end
end
