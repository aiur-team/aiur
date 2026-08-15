defmodule AiurWeb.OperatorControlCenter.AgentRoutingPreviewTest do
  use Aiur.TestSupport

  alias Aiur.{CodingAgent, Issue, Workflow}
  alias AiurWeb.OperatorControlCenter.AgentRoutingPreview

  test "predicts the routed backend, model, and effort from the configured routing table" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{3 => "codex:gpt-5.6-terra:high"})

    preview = AgentRoutingPreview.preview(["complexity:3", "agent:todo"])

    assert preview.available?
    assert preview.complexity == 3
    assert preview.backend == "codex"
    assert preview.model == "gpt-5.6-terra"
    assert preview.effort == "high"
    refute preview.remote?
  end

  test "an unrouted complexity falls back to the configured default agent" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex", agent_routing: %{5 => "codex:gpt-5.5"})

    preview = AgentRoutingPreview.preview(["complexity:1"])

    assert preview.backend == "codex"
    assert preview.complexity == 1
    # No routed model means "whatever the backend defaults to", which for a
    # backend with no configured default resolves to nil rather than a guess.
    assert is_nil(preview.model)
    assert preview.resolved_model in [nil, preview.model]
  end

  test "a model override label wins over the routing table" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{3 => "codex:gpt-5.6-terra:high"})

    preview = AgentRoutingPreview.preview(["complexity:3", "model:claude"])

    assert preview.backend == "claude"
    # An explicit backend override suppresses the routed effort so the ticket
    # never carries a codex-shaped effort onto a different backend.
    assert is_nil(preview.effort)
  end

  test "labels are compared case-insensitively, as the tracker normalizer produces them" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{4 => "codex:gpt-5.5"})

    assert AgentRoutingPreview.preview(["Complexity:4"]).complexity == 4
  end

  test "options offer only dispatchable backends" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")

    options = AgentRoutingPreview.options("codex")

    assert "codex" in options.backends
    assert options.complexities == [1, 2, 3, 4, 5]
    assert is_list(options.models)
    assert is_list(options.efforts)
  end

  test "an out-of-vocabulary selection is clamped instead of becoming a tracker label" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")

    selection =
      AgentRoutingPreview.normalize_selection(%{
        backend: "'; DROP TABLE issues; --",
        model: "not-a-model",
        effort: "not-an-effort",
        complexity: 99
      })

    assert selection == %{backend: nil, model: nil, effort: nil, complexity: nil}
    assert AgentRoutingPreview.plan(selection, []).add |> Enum.all?(&String.starts_with?(&1, "agent:"))
  end

  # Without the active-state label the orchestrator's candidate poll never sees
  # the ticket, so "add an agent" would leave it exactly as undispatchable.
  test "a confirmed selection always carries the active-state label that makes a ticket dispatchable" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex", tracker_active_states: ["Todo", "In Progress"])

    plan = AgentRoutingPreview.plan(%{backend: "codex", model: nil, effort: nil, complexity: 3}, [])

    assert "agent:todo" in plan.add
    assert "complexity:3" in plan.add
    assert "model:codex" in plan.add
    assert plan.remove == []
  end

  # The add-agent modal seeds its Model select from `resolved_model`, so a confirmed
  # selection writes `model:<backend>-<model>` rather than a bare `model:<backend>`.
  # The labels the operator confirms have to dispatch to the agent the modal showed
  # them, or the preview is a promise the daemon does not keep.
  test "the labels a confirmed selection writes dispatch to the previewed agent" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{3 => "codex:gpt-5.6-terra:high"})

    preview = AgentRoutingPreview.preview(["complexity:3"])

    selection =
      AgentRoutingPreview.normalize_selection(%{
        backend: preview.backend,
        model: preview.resolved_model,
        effort: preview.effort,
        complexity: preview.complexity
      })

    plan = AgentRoutingPreview.plan(selection, ["complexity:3"])
    issue = %Issue{id: "p", identifier: "p", labels: ["complexity:3"] ++ plan.add}

    assert CodingAgent.backend_for(issue) == preview.backend
    assert CodingAgent.resolve_model(preview.session_backend, CodingAgent.model_for(issue)) == preview.resolved_model
    assert CodingAgent.effort_for(issue) == preview.effort
  end

  # The test above seeds the selection from the routed model, so it passed even
  # while dispatch was throwing the operator's pick away. The bug only shows
  # when they *change* the Model select: the confirmed labels then carry a
  # variant that disagrees with routing for the same backend, and routing used
  # to win silently.
  test "a model the operator picks over the routed one survives to dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{3 => "codex:gpt-5.6-terra:high"})

    routed = AgentRoutingPreview.preview(["complexity:3"])
    assert routed.model == "gpt-5.6-terra"

    picked =
      AgentRoutingPreview.normalize_selection(%{
        backend: "codex",
        model: "gpt-5.6-sol",
        effort: routed.effort,
        complexity: 3
      })

    assert picked.model == "gpt-5.6-sol"

    plan = AgentRoutingPreview.plan(picked, ["complexity:3"])
    issue = %Issue{id: "p", identifier: "p", labels: ["complexity:3"] ++ plan.add}

    assert CodingAgent.backend_for(issue) == "codex"
    assert CodingAgent.model_for(issue) == "gpt-5.6-sol"

    # And the preview agrees with dispatch, so the modal is not showing one
    # model while the daemon starts another.
    assert AgentRoutingPreview.preview(["complexity:3"] ++ plan.add).model == "gpt-5.6-sol"
  end

  # A pinned tag expires with its version, so a routing entry that deliberately
  # names a family alias has to survive the modal as an alias. Preselecting the
  # version the alias currently resolves to would strand the ticket there while
  # every ticket the operator never opened followed the alias forward.
  test "a routed family alias is not silently frozen into the version it resolves to" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_routing: %{3 => "codex:sol"})

    preview = AgentRoutingPreview.preview(["complexity:3"])

    assert preview.model == "sol"
    assert preview.resolved_model != "sol", "this test is only meaningful while `sol` resolves to a concrete version"

    plan = AgentRoutingPreview.plan(AgentRoutingPreview.normalize_selection(%{backend: preview.backend, model: preview.model, effort: preview.effort, complexity: preview.complexity}), [])

    assert "model:codex-sol" in plan.add
    refute "model:codex-#{preview.resolved_model}" in plan.add
  end

  # `complexity_level/1` takes the highest matching label and the model override
  # takes the first, so appending beside an existing label would not change
  # routing at all.
  test "labels the selection replaces are removed, and unrelated labels are left alone" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")

    existing = ["complexity:5", "model:claude", "build-lane:dashboard-ui", "agent:todo"]
    plan = AgentRoutingPreview.plan(%{backend: "codex", model: nil, effort: nil, complexity: 3}, existing)

    assert "complexity:5" in plan.remove
    assert "model:claude" in plan.remove
    refute "build-lane:dashboard-ui" in plan.remove
    # Already present, so nothing to add for it.
    refute "agent:todo" in plan.add
  end

  test "an unusable selection plans no change at all" do
    assert AgentRoutingPreview.plan(%{backend: nil, model: nil, effort: nil, complexity: nil}, ["agent:todo"]).add == []
  end
end
