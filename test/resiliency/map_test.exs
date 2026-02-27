defmodule Resiliency.MapTest do
  use ExUnit.Case, async: true

  doctest Resiliency.Map

  describe "run/2,3" do
    test "maps over enumerable with bounded concurrency" do
      assert {:ok, [2, 4, 6]} =
               Resiliency.Map.run([1, 2, 3], &(&1 * 2), max_concurrency: 2)
    end

    test "returns {:ok, results} in input order" do
      result =
        Resiliency.Map.run([3, 1, 2], fn x ->
          Process.sleep(x * 20)
          x * 10
        end)

      assert {:ok, [30, 10, 20]} = result
    end

    test "cancels remaining on first error, returns {:error, reason}" do
      parent = self()

      result =
        Resiliency.Map.run(
          [1, 2, 3],
          fn
            2 ->
              raise "boom"

            x ->
              Process.sleep(100)
              send(parent, {:completed, x})
              x
          end,
          max_concurrency: 3
        )

      assert {:error, {%RuntimeError{message: "boom"}, _}} = result

      Process.sleep(200)
      refute_received {:completed, _}
    end

    test "respects max_concurrency limit" do
      counter = :counters.new(1, [])
      max_seen = :atomics.new(1, [])

      Resiliency.Map.run(
        1..10,
        fn _ ->
          :counters.add(counter, 1, 1)
          current = :counters.get(counter, 1)

          loop_max = :atomics.get(max_seen, 1)
          if current > loop_max, do: :atomics.put(max_seen, 1, current)

          Process.sleep(20)
          :counters.add(counter, 1, -1)
        end,
        max_concurrency: 3
      )

      assert :atomics.get(max_seen, 1) <= 3
    end

    test "timeout support" do
      result =
        Resiliency.Map.run(
          [1, 2, 3],
          fn _ -> Process.sleep(:infinity) end,
          timeout: 50
        )

      assert {:error, :timeout} = result
    end

    test "empty enumerable → {:ok, []}" do
      assert {:ok, []} = Resiliency.Map.run([], fn x -> x end)
    end

    test "works with non-list enumerables" do
      assert {:ok, [2, 4, 6]} = Resiliency.Map.run(1..3, &(&1 * 2))
    end

    test "default max_concurrency is System.schedulers_online()" do
      # Just verify it works without specifying max_concurrency
      assert {:ok, [1, 2, 3]} = Resiliency.Map.run([1, 2, 3], & &1)
    end

    test "single element" do
      assert {:ok, [42]} = Resiliency.Map.run([21], &(&1 * 2))
    end

    test "max_concurrency: 1 runs sequentially" do
      order = :atomics.new(1, [])

      {:ok, results} =
        Resiliency.Map.run(
          [1, 2, 3],
          fn x ->
            pos = :atomics.add_get(order, 1, 1)
            {x, pos}
          end,
          max_concurrency: 1
        )

      # With max_concurrency 1, execution order matches input order
      assert [{1, 1}, {2, 2}, {3, 3}] = results
    end

    test "max_concurrency greater than item count" do
      assert {:ok, [2, 4, 6]} =
               Resiliency.Map.run([1, 2, 3], &(&1 * 2), max_concurrency: 100)
    end

    test "handles exit failures" do
      result =
        Resiliency.Map.run(
          [1, 2, 3],
          fn
            2 -> exit(:crash)
            x -> x
          end,
          max_concurrency: 3
        )

      assert {:error, :crash} = result
    end

    test "handles throw failures" do
      result =
        Resiliency.Map.run(
          [1, 2, 3],
          fn
            2 -> throw(:oops)
            x -> x
          end,
          max_concurrency: 3
        )

      assert {:error, _} = result
    end

    test "pending items not started after error" do
      parent = self()

      Resiliency.Map.run(
        1..10,
        fn
          1 ->
            raise "boom"

          x ->
            send(parent, {:started, x})
            x
        end,
        max_concurrency: 1
      )

      Process.sleep(50)
      # With max_concurrency: 1, item 1 fails before any others start
      refute_received {:started, _}
    end

    test "large batch with bounded concurrency" do
      {:ok, results} = Resiliency.Map.run(1..100, &(&1 * 2), max_concurrency: 5)
      assert results == Enum.map(1..100, &(&1 * 2))
    end
  end

  describe "process cleanup" do
    test "map cleans up after error" do
      parent = self()

      Resiliency.Map.run(
        1..5,
        fn
          3 ->
            raise "boom"

          x ->
            send(parent, {:pid, self()})
            Process.sleep(5_000)
            x
        end,
        max_concurrency: 5
      )

      # Collect tracked pids
      pids = collect_pids([])
      assert pids != []

      Process.sleep(100)
      Enum.each(pids, fn pid -> refute Process.alive?(pid) end)
    end
  end

  defp collect_pids(acc) do
    receive do
      {:pid, pid} -> collect_pids([pid | acc])
    after
      0 -> acc
    end
  end
end
