defmodule Resiliency.BulkheadTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-bh-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :bulkhead, :call, :start],
      [:resiliency, :bulkhead, :call, :stop],
      [:resiliency, :bulkhead, :call, :rejected],
      [:resiliency, :bulkhead, :call, :permitted]
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

  describe "successful call emits start, permitted, and stop" do
    test "emits start, permitted, and stop with result: :ok" do
      bh = start_bulkhead!()

      assert {:ok, 42} = Resiliency.Bulkhead.call(bh, fn -> 42 end)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], %{system_time: st},
                       %{name: ^bh}}

      assert is_integer(st)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], %{}, %{name: ^bh}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], %{duration: duration},
                       %{name: ^bh, result: :ok, error: nil}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "rejected call emits start, rejected, and stop" do
    test "emits start, rejected, and stop with result: :error on bulkhead full" do
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

      # This call should be rejected
      assert {:error, :bulkhead_full} = Resiliency.Bulkhead.call(bh, fn -> :never end)

      # The filling task emits its own start/permitted, so we consume those first
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], _, _}
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], _, _}

      # Now the rejected call's events
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], %{system_time: st},
                       %{name: ^bh}}

      assert is_integer(st)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :rejected], %{}, %{name: ^bh}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], %{duration: duration},
                       %{name: ^bh, result: :error, error: :bulkhead_full}}

      assert is_integer(duration)
      assert duration >= 0

      gate_open(gate)
      Task.await(task)
    end
  end

  describe "error call emits start, permitted, and stop with error" do
    test "emits stop with result: :error when function raises" do
      bh = start_bulkhead!()

      assert {:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
               Resiliency.Bulkhead.call(bh, fn -> raise "boom" end)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], %{system_time: _},
                       %{name: ^bh}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], %{}, %{name: ^bh}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], %{duration: duration},
                       %{name: ^bh, result: :error, error: error}}

      assert is_integer(duration)
      assert duration >= 0
      assert {%RuntimeError{message: "boom"}, _stacktrace} = error
    end

    test "emits stop with result: :error when function exits" do
      bh = start_bulkhead!()

      assert {:error, :oops} = Resiliency.Bulkhead.call(bh, fn -> exit(:oops) end)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], _, %{name: ^bh}}
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], _, %{name: ^bh}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], %{duration: duration},
                       %{name: ^bh, result: :error, error: :oops}}

      assert is_integer(duration)
      assert duration >= 0
    end

    test "emits stop with result: :error when function throws" do
      bh = start_bulkhead!()

      assert {:error, {:nocatch, :thrown}} =
               Resiliency.Bulkhead.call(bh, fn -> throw(:thrown) end)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], _, %{name: ^bh}}
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], _, %{name: ^bh}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], %{duration: duration},
                       %{name: ^bh, result: :error, error: {:nocatch, :thrown}}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "metadata includes name in all events" do
    test "name is present in start, permitted, and stop metadata" do
      bh = start_bulkhead!()
      Resiliency.Bulkhead.call(bh, fn -> :ok end)

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], _,
                       %{name: received_name_start}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], _,
                       %{name: received_name_permitted}}

      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], _,
                       %{name: received_name_stop}}

      assert received_name_start == bh
      assert received_name_permitted == bh
      assert received_name_stop == bh
    end

    test "name is present in rejected metadata" do
      bh = start_bulkhead!(max_concurrent: 1, max_wait: 0)
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

      # Consume the filler task's events
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], _, %{name: ^bh}}
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :permitted], _, %{name: ^bh}}

      # Rejected call events
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :start], _, %{name: ^bh}}
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :rejected], _, %{name: ^bh}}
      assert_received {:telemetry, [:resiliency, :bulkhead, :call, :stop], _, %{name: ^bh}}

      gate_open(gate)
      Task.await(task)
    end
  end

  # --- Helpers ---

  defp start_bulkhead!(opts \\ []) do
    name = :"bh_tel_#{System.unique_integer([:positive])}"
    opts = Keyword.put_new(opts, :max_concurrent, 5)
    opts = Keyword.put(opts, :name, name)
    start_supervised!({Resiliency.Bulkhead, opts})
    name
  end

  defp gate_new do
    name = :"gate_tel_#{System.unique_integer([:positive])}"
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

  defp current(bh) do
    Resiliency.Bulkhead.get_stats(bh).current
  end
end
