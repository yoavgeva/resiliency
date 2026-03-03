defmodule Resiliency.SingleFlightTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-sf-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :single_flight, :flight, :start],
      [:resiliency, :single_flight, :flight, :stop],
      [:resiliency, :single_flight, :flight, :exception]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    server =
      start_supervised!(
        {Resiliency.SingleFlight, name: :"sf_tel_#{System.unique_integer([:positive])}"}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{server: server}
  end

  describe "successful flight telemetry" do
    test "emits start and stop events with result :ok and shared false for single caller",
         %{server: server} do
      assert {:ok, 42} = Resiliency.SingleFlight.flight(server, "key", fn -> 42 end)

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :start], measurements,
                       metadata}

      assert %{system_time: system_time} = measurements
      assert is_integer(system_time)
      assert %{name: ^server, key: "key"} = metadata

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :stop], measurements,
                       metadata}

      assert %{duration: duration} = measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{name: ^server, key: "key", result: :ok, shared: false} = metadata
    end
  end

  describe "error flight telemetry" do
    test "emits start and stop events with result :error and shared false for single caller",
         %{server: server} do
      assert {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
               Resiliency.SingleFlight.flight(server, "err-key", fn -> raise "boom" end)

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :start], _measurements,
                       metadata}

      assert %{name: ^server, key: "err-key"} = metadata

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :stop], measurements,
                       metadata}

      assert %{duration: duration} = measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{name: ^server, key: "err-key", result: :error, shared: false} = metadata
    end
  end

  describe "shared flight telemetry" do
    test "leader gets shared false and followers get shared true", %{server: server} do
      gate = gate_open()

      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Resiliency.SingleFlight.flight(server, "shared-key", fn ->
              gate_await(gate)
              :shared_result
            end)
          end)
        end

      # Give time for all callers to register with the server
      Process.sleep(100)

      # Open the gate so the flight completes
      gate_release(gate)

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == {:ok, :shared_result}))

      # Drain all telemetry messages and filter by this test's server
      start_events = drain_events([:resiliency, :single_flight, :flight, :start], server)
      stop_events = drain_events([:resiliency, :single_flight, :flight, :stop], server)

      assert length(start_events) == 3
      assert length(stop_events) == 3

      # All start events should have the correct name and key
      Enum.each(start_events, fn {_event, measurements, metadata} ->
        assert %{system_time: system_time} = measurements
        assert is_integer(system_time)
        assert %{name: ^server, key: "shared-key"} = metadata
      end)

      # Exactly one stop event should have shared: false (the leader)
      shared_values =
        Enum.map(stop_events, fn {_event, _measurements, metadata} -> metadata.shared end)

      assert Enum.count(shared_values, &(&1 == false)) == 1
      assert Enum.count(shared_values, &(&1 == true)) == 2

      # All stop events should have result: :ok
      Enum.each(stop_events, fn {_event, measurements, metadata} ->
        assert %{duration: duration} = measurements
        assert is_integer(duration)
        assert duration >= 0
        assert %{name: ^server, key: "shared-key", result: :ok} = metadata
      end)
    end
  end

  describe "metadata includes name and key" do
    test "start and stop events carry the server name and key", %{server: server} do
      assert {:ok, :val} =
               Resiliency.SingleFlight.flight(server, {:compound, :key}, fn -> :val end)

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :start], _measurements,
                       start_meta}

      assert start_meta.name == server
      assert start_meta.key == {:compound, :key}

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :stop], _measurements,
                       stop_meta}

      assert stop_meta.name == server
      assert stop_meta.key == {:compound, :key}
    end
  end

  describe "exception telemetry on timeout" do
    test "emits exception event when caller times out", %{server: server} do
      assert catch_exit(
               Resiliency.SingleFlight.flight(
                 server,
                 "timeout-key",
                 fn ->
                   Process.sleep(500)
                   :done
                 end,
                 50
               )
             )

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :start], _measurements,
                       metadata}

      assert %{name: ^server, key: "timeout-key"} = metadata

      assert_received {:telemetry, [:resiliency, :single_flight, :flight, :exception],
                       measurements, metadata}

      assert %{duration: duration} = measurements
      assert is_integer(duration)
      assert duration >= 0
      assert %{name: ^server, key: "timeout-key", kind: :exit} = metadata
      assert is_list(metadata.stacktrace)

      # Wait for the in-flight function to complete so it doesn't leak
      Process.sleep(600)
    end
  end

  # -- Helpers --

  defp drain_events(event_name, server) do
    drain_events(event_name, server, [])
  end

  defp drain_events(event_name, server, acc) do
    receive do
      {:telemetry, ^event_name, measurements, %{name: ^server} = metadata} ->
        drain_events(event_name, server, [{event_name, measurements, metadata} | acc])

      {:telemetry, ^event_name, _measurements, _metadata} ->
        # Discard events from other servers running concurrently
        drain_events(event_name, server, acc)
    after
      500 ->
        acc
    end
  end

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
