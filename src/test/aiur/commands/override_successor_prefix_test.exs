defmodule Aiur.Commands.OverrideSuccessorPrefixTest do
  use Aiur.TestSupport

  alias Aiur.{Decision, DecisionAnswer, DecisionRevision, Issue}
  alias Aiur.Orchestrator.OverrideSuccessor

  defmodule Tracker do
    def update_issue_state("70", "todo", []) do
      {storage, prefix} = Process.get(:successor_prefix_tracker)
      Agent.update(storage, &Map.update!(&1, :labels, fn labels -> ["#{prefix}:todo" | labels] end))
    end

    def remove_label("70", label) do
      {storage, _prefix} = Process.get(:successor_prefix_tracker)
      Agent.update(storage, &Map.update!(&1, :labels, fn labels -> List.delete(labels, label) end))
    end
  end

  test "configured and explicitly overridden prefixes survive successor creation and release" do
    for {configured, options, expected} <- [{"nuc", [], "nuc"}, {"agent", [label_prefix: "nuc"], "nuc"}] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", tracker_label_prefix: configured)
      now = DateTime.utc_now()
      old = struct(DecisionAnswer, action_id: "old", custom_response: "keep blue")
      answer = struct(DecisionAnswer, action_id: "override-1", custom_response: "use green")
      revision = struct(DecisionRevision, action_id: "override-1", prior_action_id: "old", answer: answer, recorded_at: now)
      record = %{action_id: "override-1", route: :replacement, state: :queued, ticket: %{identifier: "50"}, resume_reason: :branch_missing}
      decision = struct(Decision, decision_id: "command", ticket: %{identifier: "50"}, question: "Which colour?", answer: old, revisions: [revision], overrides: [record])
      storage = start_supervised!({Agent, fn -> %{labels: [], created: nil} end}, id: "prefix-#{configured}")
      Process.put(:successor_prefix_tracker, {storage, expected})

      opts =
        [
          tracker: Tracker,
          find: fn _, _ -> {:ok, nil} end,
          issues: fn ["50"] -> {:ok, [%Issue{labels: ["feature:todo", "priority:2", "nuc:in-progress"]}]} end,
          create: fn attrs, _ ->
            assert "#{expected}:parked" in attrs.labels
            refute "agent:parked" in attrs.labels
            refute "agent:todo" in attrs.labels
            refute "#{expected}:todo" in attrs.labels
            Agent.update(storage, &%{&1 | labels: attrs.labels, created: attrs})
            {:ok, %{"number" => 70, "title" => attrs.title, "url" => "https://example.test/70"}}
          end,
          close_fun: fn 60, "70" -> :ok end,
          comment_fun: fn "50", _ -> :ok end,
          marker_fun: fn "50", :add, label ->
            assert label == "#{expected}:parked"
            :ok
          end
        ] ++ options

      assert {:ok, %{identifier: "70"}} = OverrideSuccessor.reconcile(decision, record, %{number: 60, merged?: false}, opts)
      assert Agent.get(storage, & &1.labels) |> Enum.sort() == Enum.sort(["feature:todo", "priority:2", "complexity:2", "#{expected}:todo"])
    end
  end
end
