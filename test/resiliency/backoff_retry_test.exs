defmodule Resiliency.BackoffRetryTest do
  use ExUnit.Case, async: true

  doctest Resiliency.BackoffRetry

  defp no_sleep, do: fn _ -> :ok end

  describe "success" do
    test "returns {:ok, value} on first attempt success" do
      assert Resiliency.BackoffRetry.retry(fn -> {:ok, 42} end, sleep_fn: no_sleep()) == {:ok, 42}
    end

    test "wraps bare return values in {:ok, _}" do
      assert Resiliency.BackoffRetry.retry(fn -> 42 end, sleep_fn: no_sleep()) == {:ok, 42}
    end

    test "passes through {:ok, value} unchanged" do
      assert Resiliency.BackoffRetry.retry(fn -> {:ok, :hello} end, sleep_fn: no_sleep()) ==
               {:ok, :hello}
    end

    test "wraps nil in {:ok, nil}" do
      assert Resiliency.BackoffRetry.retry(fn -> nil end, sleep_fn: no_sleep()) == {:ok, nil}
    end

    test "wraps :ok as {:ok, :ok}" do
      assert Resiliency.BackoffRetry.retry(fn -> :ok end, sleep_fn: no_sleep()) == {:ok, :ok}
    end

    test "wraps :error as {:error, :error}" do
      assert Resiliency.BackoffRetry.retry(fn -> :error end,
               sleep_fn: no_sleep(),
               max_attempts: 1
             ) ==
               {:error, :error}
    end
  end

  describe "retry on failure" do
    test "retries on {:error, _} and eventually succeeds" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, n)
            if n < 3, do: {:error, :fail}, else: {:ok, :success}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 5
        )

      assert result == {:ok, :success}
      assert :counters.get(counter, 1) == 3
    end

    test "retries on raise and eventually succeeds" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, n)
            if n < 2, do: raise("boom"), else: {:ok, :recovered}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 3
        )

      assert result == {:ok, :recovered}
    end

    test "retries on exit" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, n)
            if n < 2, do: exit(:boom), else: {:ok, :recovered}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 3
        )

      assert result == {:ok, :recovered}
    end

    test "retries on throw" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, n)
            if n < 2, do: throw(:boom), else: {:ok, :recovered}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 3
        )

      assert result == {:ok, :recovered}
    end

    test "returns last error after exhausting all attempts" do
      result =
        Resiliency.BackoffRetry.retry(fn -> {:error, :always_fail} end,
          sleep_fn: no_sleep(),
          max_attempts: 3
        )

      assert result == {:error, :always_fail}
    end
  end

  describe "max_attempts" do
    test "respects max_attempts limit" do
      counter = :counters.new(1, [:atomics])

      Resiliency.BackoffRetry.retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, :fail}
        end,
        sleep_fn: no_sleep(),
        max_attempts: 5
      )

      assert :counters.get(counter, 1) == 5
    end

    test "max_attempts: 1 means no retries" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 1
        )

      assert result == {:error, :fail}
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "retry_if" do
    test "predicate controls which errors are retried" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :not_found}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 5,
          retry_if: fn
            {:error, :timeout} -> true
            _ -> false
          end
        )

      assert result == {:error, :not_found}
      # Only 1 attempt since retry_if returned false
      assert :counters.get(counter, 1) == 1
    end

    test "receives {:error, reason} tuple" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :some_error} end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        retry_if: fn error ->
          send(parent, {:retry_if, ref, error})
          true
        end
      )

      assert_received {:retry_if, ^ref, {:error, :some_error}}
    end

    test "receives wrapped exception for raised errors" do
      ref = make_ref()
      parent = self()

      Resiliency.BackoffRetry.retry(
        fn -> raise "test error" end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        retry_if: fn
          {:error, %RuntimeError{}} ->
            send(parent, {:got_exception, ref})
            true

          _ ->
            false
        end
      )

      assert_received {:got_exception, ^ref}
    end
  end

  describe "three-element error tuples" do
    test "normalizes {:error, reason, metadata} into {:error, {reason, metadata}}" do
      result =
        Resiliency.BackoffRetry.retry(fn -> {:error, :timeout, %{code: 408}} end,
          sleep_fn: no_sleep(),
          max_attempts: 1
        )

      assert result == {:error, {:timeout, %{code: 408}}}
    end

    test "retries on {:error, reason, metadata}" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, n)
            if n < 3, do: {:error, :unavailable, %{grpc_status: 14}}, else: {:ok, :success}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 5
        )

      assert result == {:ok, :success}
      assert :counters.get(counter, 1) == 3
    end

    test "retry_if receives {:error, {reason, metadata}}" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :unavailable, %{grpc_status: 14}} end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        retry_if: fn error ->
          send(parent, {:retry_if, ref, error})
          true
        end
      )

      assert_received {:retry_if, ^ref, {:error, {:unavailable, %{grpc_status: 14}}}}
    end

    test "abort with 3-tuple stops immediately" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, Resiliency.BackoffRetry.abort(:fatal), %{extra: true}}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 10
        )

      assert result == {:error, :fatal}
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "abort" do
    test "stops immediately and unwraps reason" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, Resiliency.BackoffRetry.abort(:fatal)}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 10
        )

      assert result == {:error, :fatal}
      assert :counters.get(counter, 1) == 1
    end

    test "overrides retry_if" do
      result =
        Resiliency.BackoffRetry.retry(
          fn -> {:error, Resiliency.BackoffRetry.abort(:stop)} end,
          sleep_fn: no_sleep(),
          max_attempts: 10,
          retry_if: fn _ -> true end
        )

      assert result == {:error, :stop}
    end
  end

  describe "stack trace preservation" do
    test "default returns {:error, exception} without raising" do
      result =
        Resiliency.BackoffRetry.retry(fn -> raise "boom" end,
          sleep_fn: no_sleep(),
          max_attempts: 1
        )

      assert {:error, %RuntimeError{message: "boom"}} = result
    end

    test "reraise: true re-raises rescued exception" do
      assert_raise RuntimeError, "boom", fn ->
        Resiliency.BackoffRetry.retry(fn -> raise "boom" end,
          sleep_fn: no_sleep(),
          max_attempts: 2,
          reraise: true
        )
      end
    end

    test "reraise: true does not affect {:error, reason} returns" do
      result =
        Resiliency.BackoffRetry.retry(fn -> {:error, :not_found} end,
          sleep_fn: no_sleep(),
          max_attempts: 2,
          reraise: true
        )

      assert result == {:error, :not_found}
    end

    test "reraise: true preserves original stacktrace" do
      try do
        Resiliency.BackoffRetry.retry(fn -> raise "trace me" end,
          sleep_fn: no_sleep(),
          max_attempts: 2,
          reraise: true
        )
      rescue
        e in RuntimeError ->
          stacktrace = __STACKTRACE__
          assert e.message == "trace me"
          # The top of the stacktrace should reference the anonymous function,
          # not Resiliency.BackoffRetry internals
          [{mod, _fun, _arity, _meta} | _rest] = stacktrace
          assert mod != Resiliency.BackoffRetry
      end
    end

    test "reraise: true works after multiple retries" do
      counter = :counters.new(1, [:atomics])

      assert_raise RuntimeError, "always fails", fn ->
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            raise "always fails"
          end,
          sleep_fn: no_sleep(),
          max_attempts: 4,
          reraise: true
        )
      end

      assert :counters.get(counter, 1) == 4
    end
  end

  describe "budget" do
    test "stops when budget would be exceeded by next sleep" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          sleep_fn: fn ms -> Process.sleep(ms) end,
          max_attempts: 100,
          backoff: [10, 10, 10, 10, 10],
          budget: 30
        )

      assert result == {:error, :fail}
      # Should have done fewer than 100 attempts
      attempts = :counters.get(counter, 1)
      assert attempts < 100
      assert attempts >= 2
    end

    test ":infinity default means no budget" do
      counter = :counters.new(1, [:atomics])

      Resiliency.BackoffRetry.retry(
        fn ->
          :counters.add(counter, 1, 1)
          {:error, :fail}
        end,
        sleep_fn: no_sleep(),
        max_attempts: 5
      )

      assert :counters.get(counter, 1) == 5
    end
  end

  describe "on_retry" do
    test "called with correct (attempt, delay, error)" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: no_sleep(),
        max_attempts: 3,
        backoff: [100, 200],
        on_retry: fn attempt, delay, error ->
          send(parent, {:on_retry, ref, attempt, delay, error})
        end
      )

      assert_received {:on_retry, ^ref, 1, 100, {:error, :fail}}
      assert_received {:on_retry, ^ref, 2, 200, {:error, :fail}}
    end

    test "not called on first attempt (only on retries)" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        backoff: [100],
        on_retry: fn attempt, _delay, _error ->
          send(parent, {:on_retry, ref, attempt})
        end
      )

      # First on_retry call is for attempt 1 (the first *retry*, after the initial call)
      assert_received {:on_retry, ^ref, 1}
      refute_received {:on_retry, ^ref, 0}
    end

    test "not called on success" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:ok, :success} end,
        sleep_fn: no_sleep(),
        max_attempts: 3,
        on_retry: fn _attempt, _delay, _error ->
          send(parent, {:on_retry, ref})
        end
      )

      refute_received {:on_retry, ^ref}
    end
  end

  describe "backoff integration" do
    test "default exponential backoff" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 4
      )

      collected = Agent.get(delays_agent, & &1)
      # Default: exponential base=100, capped at 5000
      assert collected == [100, 200, 400]
    end

    test ":linear backoff" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 4,
        backoff: :linear
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [100, 200, 300]
    end

    test ":constant backoff" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 4,
        backoff: :constant
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [100, 100, 100]
    end

    test "custom list of delays" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 4,
        backoff: [50, 150, 500]
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [50, 150, 500]
    end

    test "custom stream" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 4,
        backoff:
          Resiliency.BackoffRetry.Backoff.exponential(base: 200)
          |> Resiliency.BackoffRetry.Backoff.cap(1000)
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [200, 400, 800]
    end

    test "max_delay caps delays" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 6,
        max_delay: 300
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [100, 200, 300, 300, 300]
    end

    test "base_delay controls starting delay" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 4,
        base_delay: 50
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [50, 100, 200]
    end
  end

  describe "sleep_fn" do
    test "receives delay value" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> send(parent, {:sleep, ref, ms}) end,
        max_attempts: 2,
        backoff: [42]
      )

      assert_received {:sleep, ^ref, 42}
    end

    test "replaces Process.sleep" do
      # This should complete instantly with no-op sleep
      {time, _result} =
        :timer.tc(fn ->
          Resiliency.BackoffRetry.retry(
            fn -> {:error, :fail} end,
            sleep_fn: no_sleep(),
            max_attempts: 10,
            backoff: [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
          )
        end)

      # Should be well under 1 second (no actual sleeping)
      assert time < 100_000
    end
  end

  describe "edge cases" do
    test "succeeds on exactly the last attempt" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            n = :counters.get(counter, 1) + 1
            :counters.put(counter, 1, n)
            if n < 5, do: {:error, :fail}, else: {:ok, :phew}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 5
        )

      assert result == {:ok, :phew}
      assert :counters.get(counter, 1) == 5
    end

    test "{:error, nil} retries and returns correctly" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, nil}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 3
        )

      assert result == {:error, nil}
      assert :counters.get(counter, 1) == 3
    end

    test "nested tuples {:ok, {:error, _}} treated as success" do
      result =
        Resiliency.BackoffRetry.retry(
          fn -> {:ok, {:error, :inner}} end,
          sleep_fn: no_sleep(),
          max_attempts: 3
        )

      assert result == {:ok, {:error, :inner}}
    end

    test "double-wrapped abort unwraps once" do
      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            {:error, Resiliency.BackoffRetry.abort(Resiliency.BackoffRetry.abort(:x))}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 5
        )

      assert {:error, %Resiliency.BackoffRetry.Abort{reason: :x}} = result
    end

    test "backoff list shorter than max_attempts limits retries to list length" do
      counter = :counters.new(1, [:atomics])
      delays_agent = start_delay_collector()

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
          max_attempts: 10,
          backoff: [100, 200]
        )

      assert result == {:error, :fail}
      # List has 2 elements → 2 retries → 3 attempts total
      assert :counters.get(counter, 1) == 3
      assert Agent.get(delays_agent, & &1) == [100, 200]
    end

    test "empty backoff list behaves like max_attempts: 1" do
      counter = :counters.new(1, [:atomics])

      result =
        Resiliency.BackoffRetry.retry(
          fn ->
            :counters.add(counter, 1, 1)
            {:error, :fail}
          end,
          sleep_fn: no_sleep(),
          max_attempts: 10,
          backoff: []
        )

      assert result == {:error, :fail}
      assert :counters.get(counter, 1) == 1
    end

    test "backoff as a Range" do
      delays_agent = start_delay_collector()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> Agent.update(delays_agent, fn acc -> acc ++ [ms] end) end,
        max_attempts: 5,
        backoff: 100..400//100
      )

      collected = Agent.get(delays_agent, & &1)
      assert collected == [100, 200, 300, 400]
    end
  end

  describe "callback contracts" do
    test "on_retry receives correct wrapped error for raise" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> raise "boom" end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        on_retry: fn _attempt, _delay, error ->
          send(parent, {:on_retry, ref, error})
        end
      )

      assert_received {:on_retry, ^ref, {:error, %RuntimeError{message: "boom"}}}
    end

    test "on_retry receives correct wrapped error for exit" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> exit(:boom) end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        on_retry: fn _attempt, _delay, error ->
          send(parent, {:on_retry, ref, error})
        end
      )

      assert_received {:on_retry, ^ref, {:error, {:exit, :boom}}}
    end

    test "on_retry receives correct wrapped error for throw" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> throw(:boom) end,
        sleep_fn: no_sleep(),
        max_attempts: 2,
        on_retry: fn _attempt, _delay, error ->
          send(parent, {:on_retry, ref, error})
        end
      )

      assert_received {:on_retry, ^ref, {:error, {:throw, :boom}}}
    end

    test "on_retry NOT called when retry_if returns false" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: no_sleep(),
        max_attempts: 5,
        retry_if: fn _ -> false end,
        on_retry: fn _attempt, _delay, _error ->
          send(parent, {:on_retry, ref})
        end
      )

      refute_received {:on_retry, ^ref}
    end

    test "on_retry called BEFORE sleep_fn" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn _ms -> send(parent, {:event, ref, :sleep}) end,
        max_attempts: 2,
        backoff: [100],
        on_retry: fn _attempt, _delay, _error ->
          send(parent, {:event, ref, :on_retry})
        end
      )

      events =
        Stream.repeatedly(fn ->
          receive do
            {:event, ^ref, event} -> event
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert events == [:on_retry, :sleep]
    end

    test "sleep_fn called exactly max_attempts - 1 times on full exhaustion" do
      sleep_counter = :counters.new(1, [:atomics])

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn _ms -> :counters.add(sleep_counter, 1, 1) end,
        max_attempts: 5
      )

      assert :counters.get(sleep_counter, 1) == 4
    end

    test "on_retry delay matches sleep_fn delay" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, :fail} end,
        sleep_fn: fn ms -> send(parent, {:sleep_delay, ref, ms}) end,
        max_attempts: 4,
        backoff: [10, 20, 30],
        on_retry: fn _attempt, delay, _error ->
          send(parent, {:retry_delay, ref, delay})
        end
      )

      for expected <- [10, 20, 30] do
        assert_received {:retry_delay, ^ref, ^expected}
        assert_received {:sleep_delay, ^ref, ^expected}
      end
    end

    test "abort bypasses retry_if (retry_if never called)" do
      parent = self()
      ref = make_ref()

      Resiliency.BackoffRetry.retry(
        fn -> {:error, Resiliency.BackoffRetry.abort(:stop)} end,
        sleep_fn: no_sleep(),
        max_attempts: 10,
        retry_if: fn _error ->
          send(parent, {:retry_if_called, ref})
          true
        end
      )

      refute_received {:retry_if_called, ^ref}
    end
  end

  describe "concurrency" do
    test "concurrent retry calls don't interfere" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            counter = :counters.new(1, [:atomics])

            result =
              Resiliency.BackoffRetry.retry(
                fn ->
                  n = :counters.get(counter, 1) + 1
                  :counters.put(counter, 1, n)
                  if n < 3, do: {:error, :fail}, else: {:ok, i}
                end,
                sleep_fn: no_sleep(),
                max_attempts: 5
              )

            {result, :counters.get(counter, 1)}
          end)
        end

      results = Task.await_many(tasks, 5000)

      for {i, {result, attempts}} <- Enum.with_index(results, 1) do
        assert result == {:ok, i}
        assert attempts == 3
      end
    end
  end

  defp start_delay_collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    agent
  end
end
