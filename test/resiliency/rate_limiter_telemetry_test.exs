defmodule Resiliency.RateLimiterTelemetryTest do
  use ExUnit.Case, async: true

  setup do
    handler_id = "test-rl-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :rate_limiter, :call, :start],
      [:resiliency, :rate_limiter, :call, :stop],
      [:resiliency, :rate_limiter, :call, :rejected]
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

  # --- Helpers ---

  defp start_rl!(opts \\ []) do
    name = :"rl_tel_#{System.unique_integer([:positive])}"

    opts =
      opts
      |> Keyword.put_new(:rate, 100.0)
      |> Keyword.put_new(:burst_size, 10)
      |> Keyword.put(:name, name)

    start_supervised!({Resiliency.RateLimiter, opts})
    name
  end

  # Drain test mailbox of any stale telemetry messages
  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end

  # --- start + stop on success ---

  describe "successful call emits start and stop" do
    test "emits :start with system_time and :stop with duration, result: :ok, error: nil" do
      rl = start_rl!()

      assert {:ok, 42} = Resiliency.RateLimiter.call(rl, fn -> 42 end)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :start],
                       %{system_time: st}, %{name: ^rl}}

      assert is_integer(st)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :stop],
                       %{duration: duration}, %{name: ^rl, result: :ok, error: nil}}

      assert is_integer(duration)
      assert duration >= 0
    end

    test "no :rejected event on success" do
      rl = start_rl!()
      flush_telemetry()

      Resiliency.RateLimiter.call(rl, fn -> :ok end)

      refute_received {:telemetry, [:resiliency, :rate_limiter, :call, :rejected], _, _}
    end
  end

  # --- stop with result: :error when function raises ---

  describe "stop with result: :error when function raises" do
    test "emits :stop with result: :error and the exception as error" do
      rl = start_rl!()

      assert {:error, {%RuntimeError{message: "boom"}, _}} =
               Resiliency.RateLimiter.call(rl, fn -> raise "boom" end)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :start], _, %{name: ^rl}}

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :stop],
                       %{duration: duration},
                       %{name: ^rl, result: :error, error: {%RuntimeError{}, _stacktrace}}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  # --- start + rejected + stop on rejection ---

  describe "rejected call emits start, rejected, and stop" do
    test "emits :start, :rejected with retry_after, :stop with result: :error" do
      rl = start_rl!(rate: 0.001, burst_size: 1)

      # Drain the bucket
      assert {:ok, _} = Resiliency.RateLimiter.call(rl, fn -> :ok end)
      flush_telemetry()

      assert {:error, {:rate_limited, _ms}} = Resiliency.RateLimiter.call(rl, fn -> :ok end)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :start],
                       %{system_time: st}, %{name: ^rl}}

      assert is_integer(st)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :rejected],
                       %{retry_after: retry_after}, %{name: ^rl}}

      assert is_integer(retry_after)
      assert retry_after >= 1

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :stop],
                       %{duration: duration},
                       %{name: ^rl, result: :error, error: {:rate_limited, _}}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  # --- retry_after grows with lower rate ---

  describe "retry_after scales with rate" do
    test "lower rate produces larger retry_after" do
      rl_fast = start_rl!(rate: 100.0, burst_size: 1)
      rl_slow = start_rl!(rate: 1.0, burst_size: 1)

      Resiliency.RateLimiter.call(rl_fast, fn -> :ok end)
      Resiliency.RateLimiter.call(rl_slow, fn -> :ok end)
      flush_telemetry()

      Resiliency.RateLimiter.call(rl_fast, fn -> :ok end)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :rejected],
                       %{retry_after: fast_retry}, %{name: ^rl_fast}}

      Resiliency.RateLimiter.call(rl_slow, fn -> :ok end)

      assert_received {:telemetry, [:resiliency, :rate_limiter, :call, :rejected],
                       %{retry_after: slow_retry}, %{name: ^rl_slow}}

      assert slow_retry > fast_retry
    end
  end
end
