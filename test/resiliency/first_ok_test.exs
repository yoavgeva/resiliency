defmodule Resiliency.FirstOkTest do
  use ExUnit.Case, async: true

  doctest Resiliency.FirstOk

  describe "run/1,2" do
    test "returns first success" do
      assert {:ok, :hello} = Resiliency.FirstOk.run([fn -> :hello end])
    end

    test "skips failures, returns later success" do
      assert {:ok, :second} =
               Resiliency.FirstOk.run([
                 fn -> raise "boom" end,
                 fn -> :second end
               ])
    end

    test "returns {:error, :all_failed} when all fail" do
      assert {:error, :all_failed} =
               Resiliency.FirstOk.run([
                 fn -> raise "one" end,
                 fn -> exit(:two) end,
                 fn -> throw(:three) end
               ])
    end

    test "treats {:error, _} return values as failures" do
      assert {:ok, :winner} =
               Resiliency.FirstOk.run([
                 fn -> {:error, :miss} end,
                 fn -> :winner end
               ])
    end

    test "passes through {:ok, value} return values" do
      assert {:ok, "found"} =
               Resiliency.FirstOk.run([
                 fn -> {:error, :miss} end,
                 fn -> {:ok, "found"} end
               ])
    end

    test "treats raises as failures" do
      assert {:ok, :ok} =
               Resiliency.FirstOk.run([
                 fn -> raise "boom" end,
                 fn -> :ok end
               ])
    end

    test "treats exits as failures" do
      assert {:ok, :ok} =
               Resiliency.FirstOk.run([
                 fn -> exit(:crash) end,
                 fn -> :ok end
               ])
    end

    test "treats throws as failures" do
      assert {:ok, :ok} =
               Resiliency.FirstOk.run([
                 fn -> throw(:oops) end,
                 fn -> :ok end
               ])
    end

    test "empty list → {:error, :empty}" do
      assert {:error, :empty} = Resiliency.FirstOk.run([])
    end

    test "wraps non-tuple return values in {:ok, _}" do
      assert {:ok, 42} = Resiliency.FirstOk.run([fn -> 42 end])
      assert {:ok, "hello"} = Resiliency.FirstOk.run([fn -> "hello" end])
      assert {:ok, [1, 2]} = Resiliency.FirstOk.run([fn -> [1, 2] end])
    end

    test "timeout stops trying remaining functions" do
      parent = self()

      result =
        Resiliency.FirstOk.run(
          [
            fn ->
              Process.sleep(200)
              {:error, :slow}
            end,
            fn ->
              send(parent, :second_tried)
              :should_not_reach
            end
          ],
          timeout: 50
        )

      assert {:error, :all_failed} = result
      refute_received :second_tried
    end

    test "returns first success after many prior failures" do
      funs =
        List.duplicate(fn -> {:error, :nope} end, 10) ++
          [fn -> :winner end] ++
          List.duplicate(fn -> :should_not_reach end, 5)

      assert {:ok, :winner} = Resiliency.FirstOk.run(funs)
    end

    test "nil return value wrapped correctly" do
      assert {:ok, nil} = Resiliency.FirstOk.run([fn -> nil end])
    end

    test "{:ok, nil} passthrough" do
      assert {:ok, nil} = Resiliency.FirstOk.run([fn -> {:ok, nil} end])
    end

    test "does not execute functions after first success" do
      parent = self()

      Resiliency.FirstOk.run([
        fn -> :winner end,
        fn ->
          send(parent, :should_not_run)
          :second
        end
      ])

      Process.sleep(50)
      refute_received :should_not_run
    end
  end
end
