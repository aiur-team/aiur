defmodule AiurWeb.Streamdeck.Deck.PriorityTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.Priority

  test "moves one place earlier and returns the queue read-back" do
    opts = queue(3)
    assert Priority.step("4", :up, 1, opts) == {:ok, %{queue: "ops", position: 2}}
    assert_received {:reorder, "4", 2}
    refute_received {:reorder, _, _}
  end

  test "coalesces three detents into one write and clamps at the start" do
    opts = queue(3)
    assert Priority.step("4", :up, 3, opts) == {:ok, %{queue: "ops", position: 0}}
    assert_received {:reorder, "4", 0}
    refute_received {:reorder, _, _}
  end

  test "moves later and clamps at the end" do
    opts = queue(0)
    assert Priority.step("4", :down, 32, opts) == {:ok, %{queue: "ops", position: 3}}
    assert_received {:reorder, "4", 3}
    refute_received {:reorder, _, _}
  end

  test "edges are no-ops without a write in either direction" do
    assert Priority.step("4", :up, 1, queue(0)) == {:ok, :at_edge}
    assert Priority.step("4", :down, 1, queue(3)) == {:ok, :at_edge}
    refute_received {:reorder, _, _}
  end

  test "not queued, fixed plan order and disabled queues refuse without a write" do
    opts = queue(3)
    assert Priority.step("999", :up, 1, opts) == {:error, :not_queued}
    assert Priority.step("4", :up, 1, Keyword.put(opts, :show_fun, fn -> model(3, :build_order) end)) == {:error, :not_list}
    assert Priority.step("4", :up, 1, Keyword.put(opts, :show_fun, fn -> %{status: :disabled} end)) == {:error, :disabled}
    refute_received {:reorder, _, _}
  end

  test "unknown outcomes and unavailable results are returned without retry" do
    for {result, reason} <- [{{:error, :outcome_unknown}, :outcome_unknown}, {{:unavailable, :not_list}, :not_list}, {{:error, :invalid_position}, :invalid_position}] do
      opts =
        queue(3)
        |> Keyword.put(:reorder_fun, fn id, at ->
          send(self(), {:reorder, id, at})
          result
        end)

      assert Priority.step("4", :up, 1, opts) == {:error, reason}
      assert_received {:reorder, "4", 2}
      refute_received {:reorder, _, _}
    end
  end

  test "reports the observed position rather than assuming the requested move won" do
    opts = queue(3) |> Keyword.put(:reorder_fun, fn _, _ -> :ok end)
    assert Priority.step("4", :up, 1, opts) == {:ok, %{queue: "ops", position: 3}}
  end

  test "a failed read-back never reports an invented position" do
    opts =
      queue(3)
      |> Keyword.put(:reorder_fun, fn _, _ ->
        Process.put(:priority_model, %{status: :read_timeout})
        :ok
      end)

    assert Priority.step("4", :up, 1, opts) == {:error, :read_timeout}
  end

  test "a carried timeout model refuses a move instead of trusting an old position" do
    opts = queue(3) |> Keyword.put(:show_fun, fn -> Map.put(model(3), :snapshot, %{carried_age_ms: 100}) end)
    assert Priority.step("4", :up, 1, opts) == {:error, :read_timeout}
    refute_received {:reorder, _, _}
  end

  defp queue(position) do
    Process.put(:priority_model, model(position))

    [
      show_fun: fn -> Process.get(:priority_model) end,
      reorder_fun: fn id, at ->
        send(self(), {:reorder, id, at})
        Process.put(:priority_model, model(at))
        :ok
      end
    ]
  end

  defp model(position, kind \\ :list) do
    %{status: :running, queues: [%{kind: kind, name: "ops", items: [%{number: 4, position: position} | Enum.map(1..3, &%{number: &1, position: &1 - 1})]}]}
  end
end
