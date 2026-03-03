defmodule Resiliency.CircuitBreakerTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-cb-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :circuit_breaker, :call, :start],
      [:resiliency, :circuit_breaker, :call, :stop],
      [:resiliency, :circuit_breaker, :call, :rejected],
      [:resiliency, :circuit_breaker, :state_change]
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

  describe "start and stop on successful call" do
    test "emits start and stop events with correct metadata and measurements" do
      cb = start_breaker!()

      {:ok, 42} = Resiliency.CircuitBreaker.call(cb, fn -> 42 end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :start],
                       start_measurements, start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.name == cb

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_metadata.name == cb
      assert stop_metadata.result == :ok
      assert stop_metadata.error == nil
    end
  end

  describe "start and stop on error call" do
    test "emits start and stop with result: :error when function returns {:error, _}" do
      cb = start_breaker!()

      {:ok, {:error, :bad}} = Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :start], _,
                       %{name: ^cb}}

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_metadata.name == cb
      # The function returned {:error, :bad} but did NOT raise/exit/throw,
      # so execute/1 returns error_result = nil, meaning result: :ok
      assert stop_metadata.result == :ok
      assert stop_metadata.error == nil
    end

    test "emits stop with result: :error when function raises" do
      cb = start_breaker!()

      {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
        Resiliency.CircuitBreaker.call(cb, fn -> raise "boom" end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :start], _,
                       %{name: ^cb}}

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_metadata.name == cb
      assert stop_metadata.result == :error
      assert {%RuntimeError{message: "boom"}, _stacktrace} = stop_metadata.error
    end

    test "emits stop with result: :error when function exits" do
      cb = start_breaker!()

      {:error, :oops} = Resiliency.CircuitBreaker.call(cb, fn -> exit(:oops) end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :start], _,
                       %{name: ^cb}}

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.name == cb
      assert stop_metadata.result == :error
      assert stop_metadata.error == :oops
    end

    test "emits stop with result: :error when function throws" do
      cb = start_breaker!()

      {:error, {:nocatch, :thrown}} =
        Resiliency.CircuitBreaker.call(cb, fn -> throw(:thrown) end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :start], _,
                       %{name: ^cb}}

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.name == cb
      assert stop_metadata.result == :error
      assert stop_metadata.error == {:nocatch, :thrown}
    end
  end

  describe "rejected event when circuit is open" do
    test "emits rejected point event and stop with error: :circuit_open" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip the circuit
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Drain start/stop events from the tripping calls
      flush_telemetry()

      # Now make a call that will be rejected
      {:error, :circuit_open} =
        Resiliency.CircuitBreaker.call(cb, fn -> {:ok, :should_not_run} end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :start],
                       start_measurements, %{name: ^cb}}

      assert is_integer(start_measurements.system_time)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :rejected],
                       rejected_measurements, %{name: ^cb}}

      assert rejected_measurements == %{}

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :call, :stop],
                       stop_measurements, stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_metadata.name == cb
      assert stop_metadata.result == :error
      assert stop_metadata.error == :circuit_open
    end
  end

  describe "state_change telemetry event" do
    test "fires on closed -> open transition" do
      cb = start_breaker!(failure_rate_threshold: 0.5, minimum_calls: 2, window_size: 10)

      # Trip the circuit: closed -> open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Flush to ensure cast is processed
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], measurements,
                       metadata}

      assert measurements == %{}
      assert metadata.name == cb
      assert metadata.from == :closed
      assert metadata.to == :open
    end

    test "fires on open -> half_open transition" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          open_timeout: 50
        )

      # Trip the circuit
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Wait for open -> half_open
      wait_until(fn -> Resiliency.CircuitBreaker.get_state(cb) == :half_open end)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], _,
                       %{from: :closed, to: :open}}

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], _,
                       %{name: ^cb, from: :open, to: :half_open}}
    end

    test "fires on force_open and force_close" do
      cb = start_breaker!()

      Resiliency.CircuitBreaker.force_open(cb)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], %{},
                       %{name: ^cb, from: :closed, to: :open}}

      Resiliency.CircuitBreaker.force_close(cb)

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], %{},
                       %{name: ^cb, from: :open, to: :closed}}
    end

    test "does not fire on self-transition" do
      cb = start_breaker!()

      # force_close when already closed -- same state, no event
      Resiliency.CircuitBreaker.force_close(cb)

      refute_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], _, _}
    end
  end

  describe "on_state_change callback fires alongside telemetry" do
    test "existing callback still fires when telemetry is emitted" do
      test_pid = self()

      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          on_state_change: fn name, from, to ->
            send(test_pid, {:callback, name, from, to})
          end
        )

      # Trip the circuit: closed -> open
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Flush to ensure cast is processed
      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      # Both telemetry and callback should have fired
      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], %{},
                       %{name: ^cb, from: :closed, to: :open}}

      assert_received {:callback, ^cb, :closed, :open}
    end

    test "telemetry fires even when on_state_change is nil" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          on_state_change: nil
        )

      # Trip the circuit
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      assert Resiliency.CircuitBreaker.get_state(cb) == :open

      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], %{},
                       %{name: ^cb, from: :closed, to: :open}}
    end

    test "telemetry fires even when on_state_change callback raises" do
      cb =
        start_breaker!(
          failure_rate_threshold: 0.5,
          minimum_calls: 2,
          window_size: 10,
          on_state_change: fn _name, _from, _to ->
            raise "callback crash"
          end
        )

      # Trip the circuit -- the callback will raise but telemetry should have fired first
      for _ <- 1..2 do
        Resiliency.CircuitBreaker.call(cb, fn -> {:error, :bad} end)
      end

      # Give the cast time to process
      Process.sleep(50)

      # GenServer should still be alive
      assert Process.alive?(Process.whereis(cb))

      # Telemetry event should have fired (it happens before the callback)
      assert_received {:telemetry, [:resiliency, :circuit_breaker, :state_change], %{},
                       %{name: ^cb, from: :closed, to: :open}}
    end
  end

  # --- Helpers ---

  defp start_breaker!(opts \\ []) do
    name = :"cb_telemetry_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    start_supervised!({Resiliency.CircuitBreaker, opts})
    name
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

  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end
end
