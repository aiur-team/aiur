defmodule Aiur.GitHub.MainFixerQueueOrderTest do
  use Aiur.TestSupport

  alias Aiur.BuildQueue.Hints
  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchCandidates, DispatchPolicy}

  setup do
    path = Workflow.workflow_file_path()
    original = File.read!(path)
    on_exit(fn -> File.write!(path, original) end)

    Hints.publish_sets(%{
      sets: [%{id: "first", rank: 0}, %{id: "second", rank: 1}],
      members: %{
        "first-start" => %{set_id: "first", position: 0},
        "first-end" => %{set_id: "first", position: 1},
        "second-start" => %{set_id: "second", position: 0}
      }
    })

    :ok
  end

  test "a ready fixer outside queue sets precedes ranked sets and their list positions" do
    configure("ranked")
    [first_start, first_end, second_start, outside, fixer] = candidates()
    input = [outside, second_start, first_end, first_start, fixer]

    assert order(input) == [fixer, first_start, first_end, second_start, outside]
    assert order(Enum.reject(input, &(&1 == fixer))) == [first_start, first_end, second_start, outside]
  end

  # Compatibility guard: disabling ranked sets already preserves ordinary dispatch order.
  test "none preserves fixer priority and ordinary priority order" do
    configure("none")
    [first_start, first_end, second_start, outside, fixer] = candidates()
    input = [outside, second_start, first_end, first_start, fixer]

    assert order(input) == [fixer, outside, second_start, first_end, first_start]
    assert order(Enum.reject(input, &(&1 == fixer))) == [outside, second_start, first_end, first_start]
  end

  defp configure(set_order) do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: "agent")
    File.write!(path, File.read!(path) <> "\nbuild_queue:\n  set_order: #{set_order}\nmerge_policy:\n  main_watch:\n    on_red: dispatch_fixer\n")
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp candidates do
    ordinary =
      for {id, priority} <- [{"first-start", 4}, {"first-end", 3}, {"second-start", 2}, {"outside", 1}], do: %Issue{id: id, identifier: "repo##{id}", state: "todo", priority: priority, blocked_by: []}

    ordinary ++ [%Issue{id: "fixer", identifier: "repo#fixer", state: "todo", priority: 4, labels: ["main-fix"], blocked_by: []}]
  end

  defp order(issues), do: DispatchCandidates.order(issues, DispatchPolicy.terminal_state_set(), issues)
end
