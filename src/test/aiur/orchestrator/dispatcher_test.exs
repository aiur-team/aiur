defmodule Aiur.Orchestrator.DispatcherTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.State

  describe "check_thrash_budget/3" do
    test "counts dispatches within window and trips over the threshold" do
      state = %State{codex_thrash_budget: %{}}
      issue_id = "issue-1"
      now_ms = 0
      # Default threshold is 6; 7 calls should trip
      {state, result} =
        Enum.reduce(1..7, {state, nil}, fn _i, {acc_state, _} ->
          case Dispatcher.check_thrash_budget(acc_state, issue_id, now_ms) do
            {:ok, next} -> {next, :ok}
            {:trip, next} -> {next, :trip}
          end
        end)

      assert result == :trip
      assert get_in(state.codex_thrash_budget, [issue_id, :count]) == 7
    end

    test "resets the window when enough time has lapsed" do
      state = %State{
        codex_thrash_budget: %{
          "issue-1" => %{window_start_ms: 0, count: 10}
        }
      }

      # 61_000ms > default 60-second window
      assert {:ok, next_state} =
               Dispatcher.check_thrash_budget(state, "issue-1", 61_000)

      assert get_in(next_state.codex_thrash_budget, ["issue-1", :count]) == 1
      assert get_in(next_state.codex_thrash_budget, ["issue-1", :window_start_ms]) == 61_000
    end

    test "accumulates count within the same window" do
      state = %State{
        codex_thrash_budget: %{
          "issue-1" => %{window_start_ms: 0, count: 2}
        }
      }

      assert {:ok, next_state} = Dispatcher.check_thrash_budget(state, "issue-1", 1_000)
      assert get_in(next_state.codex_thrash_budget, ["issue-1", :count]) == 3
    end
  end

  describe "reset_thrash_budget/2" do
    test "removes the entry for the given issue_id" do
      state = %State{
        codex_thrash_budget: %{
          "issue-1" => %{window_start_ms: 0, count: 5},
          "issue-2" => %{window_start_ms: 0, count: 1}
        }
      }

      result = Dispatcher.reset_thrash_budget(state, "issue-1")

      refute Map.has_key?(result.codex_thrash_budget, "issue-1")
      assert Map.has_key?(result.codex_thrash_budget, "issue-2")
    end
  end

  describe "revalidate_issue_for_dispatch/3" do
    test "returns :ok when issue is found and passes the retry candidate check" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:ok, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, :missing} when the fetcher returns an empty list" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, []} end

      assert {:skip, :missing} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, issue} when the issue is in a terminal state" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "done"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:skip, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:error, reason} when the fetcher fails" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:error, :network_error} end

      assert {:error, :network_error} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "passes through non-Issue values unchanged" do
      assert {:ok, :not_an_issue} =
               Dispatcher.revalidate_issue_for_dispatch(:not_an_issue, nil, nil)
    end
  end
end
