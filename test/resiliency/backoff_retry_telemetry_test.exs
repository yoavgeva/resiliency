defmodule Resiliency.BackoffRetryTelemetryTest do
  use ExUnit.Case, async: true

  defp no_sleep, do: fn _ -> :ok end

  setup do
    handler_id = "test-retry-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:resiliency, :retry, :start],
      [:resiliency, :retry, :stop],
      [:resiliency, :retry, :exception],
      [:resiliency, :retry, :retry]
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

  describe "span events" do
    test "emits start and stop on first-attempt success" do
      assert {:ok, 42} =
               Resiliency.BackoffRetry.retry(fn -> {:ok, 42} end, sleep_fn: no_sleep())

      assert_received {:telemetry, [:resiliency, :retry, :start], %{system_time: st},
                       %{max_attempts: 3}}

      assert is_integer(st)

      assert_received {:telemetry, [:resiliency, :retry, :stop], %{duration: d},
                       %{max_attempts: 3, attempts: 1, result: :ok}}

      assert d >= 0
    end

    test "emits start and stop on exhausted retries" do
      assert {:error, :fail} =
               Resiliency.BackoffRetry.retry(fn -> {:error, :fail} end,
                 sleep_fn: no_sleep(),
                 max_attempts: 2
               )

      assert_received {:telemetry, [:resiliency, :retry, :start], %{system_time: _},
                       %{max_attempts: 2}}

      assert_received {:telemetry, [:resiliency, :retry, :stop], %{duration: d},
                       %{max_attempts: 2, attempts: 2, result: :error}}

      assert d >= 0
    end

    test "emits stop with result :error on abort" do
      assert {:error, :aborted} =
               Resiliency.BackoffRetry.retry(
                 fn -> {:error, Resiliency.BackoffRetry.abort(:aborted)} end,
                 sleep_fn: no_sleep()
               )

      assert_received {:telemetry, [:resiliency, :retry, :start], _, _}

      assert_received {:telemetry, [:resiliency, :retry, :stop], %{duration: _},
                       %{attempts: 1, result: :error}}
    end

    test "emits exception event on reraise path" do
      assert_raise RuntimeError, "boom", fn ->
        Resiliency.BackoffRetry.retry(fn -> raise "boom" end,
          sleep_fn: no_sleep(),
          max_attempts: 1,
          reraise: true
        )
      end

      assert_received {:telemetry, [:resiliency, :retry, :start], _, _}

      assert_received {:telemetry, [:resiliency, :retry, :exception], %{duration: d},
                       %{
                         max_attempts: 1,
                         attempts: 1,
                         kind: :error,
                         reason: %RuntimeError{message: "boom"},
                         stacktrace: st
                       }}

      assert d >= 0
      assert is_list(st)
    end

    test "emits stop (not exception) when reraise is false" do
      assert {:error, %RuntimeError{message: "boom"}} =
               Resiliency.BackoffRetry.retry(fn -> raise "boom" end,
                 sleep_fn: no_sleep(),
                 max_attempts: 1,
                 reraise: false
               )

      assert_received {:telemetry, [:resiliency, :retry, :stop], %{duration: _},
                       %{attempts: 1, result: :error}}

      refute_received {:telemetry, [:resiliency, :retry, :exception], _, _}
    end
  end

  describe "retry point event" do
    test "emits retry event for each retry" do
      counter = :counters.new(1, [:atomics])

      Resiliency.BackoffRetry.retry(
        fn ->
          n = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, n)
          if n < 3, do: {:error, :fail}, else: {:ok, :done}
        end,
        sleep_fn: no_sleep(),
        max_attempts: 5
      )

      assert_received {:telemetry, [:resiliency, :retry, :retry], %{delay: d1},
                       %{attempt: 1, error: {:error, :fail}}}

      assert is_integer(d1)

      assert_received {:telemetry, [:resiliency, :retry, :retry], %{delay: d2},
                       %{attempt: 2, error: {:error, :fail}}}

      assert is_integer(d2)

      # No third retry since attempt 3 succeeded
      refute_received {:telemetry, [:resiliency, :retry, :retry], _, %{attempt: 3, error: _}}
    end

    test "retry event includes correct delay values" do
      Resiliency.BackoffRetry.retry(fn -> {:error, :fail} end,
        sleep_fn: no_sleep(),
        max_attempts: 3,
        backoff: :constant,
        base_delay: 50
      )

      assert_received {:telemetry, [:resiliency, :retry, :retry], %{delay: 50}, %{attempt: 1}}
      assert_received {:telemetry, [:resiliency, :retry, :retry], %{delay: 50}, %{attempt: 2}}
    end
  end

  describe "on_retry callback still fires" do
    test "on_retry fires alongside telemetry retry event" do
      test_pid = self()

      Resiliency.BackoffRetry.retry(fn -> {:error, :fail} end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        on_retry: fn attempt, delay, error ->
          send(test_pid, {:on_retry, attempt, delay, error})
        end
      )

      assert_received {:on_retry, 1, _, {:error, :fail}}
      assert_received {:telemetry, [:resiliency, :retry, :retry], _, %{attempt: 1}}
    end
  end
end
