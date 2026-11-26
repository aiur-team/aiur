defmodule AiurWeb.ExecutorBlockersTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase

  alias Aiur.DecisionStore
  alias AiurWeb.Endpoint

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    store = start_supervised!({DecisionStore, name: nil, state_dir: root, filesystem_sync_fun: fn -> :ok end})
    Phoenix.Config.put(Endpoint, :decision_store, store)
    Phoenix.Config.put(Endpoint, :dashboard_writable, true)
    {:ok, store: store}
  end

  test "the footer records an answer through DecisionEvents and removes the blocker controls", %{store: store} do
    decision = request(store, "local")
    view = footer()
    form = "#executor-decision-answer-form-#{decision.decision_id}"
    assert has_element?(view, form)

    view
    |> element(form)
    |> render_submit(%{"decision_id" => decision.decision_id, "answer" => %{"choice" => "option:yes"}})

    assert {:ok, %{answer: %{actor: %{kind: :operator}, selected_option_id: "yes", decision_version: version}}} = DecisionStore.get(decision.decision_id, store)
    assert version == decision.version
    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &(&1.type == :answer_recorded)) == 1
    assert has_element?(view, "#executor-blockers .decision-answer-summary", "Yes")
    refute has_element?(view, form)
  end

  test "an answer from another surface updates the read-only footer live", %{store: store} do
    Phoenix.Config.put(Endpoint, :dashboard_writable, false)
    decision = request(store, "remote")
    view = footer()
    card = "#executor-conversation-command-#{decision.decision_id}"
    assert has_element?(view, card <> "[data-command-state=pending]")
    refute has_element?(view, card <> " form")

    assert {:ok, _} =
             DecisionStore.answer(
               decision.decision_id,
               %{"option_id" => "yes", "expected_version" => decision.version, "idempotency_key" => "other-surface"},
               [actor: %{kind: :operator, id: "other-surface"}],
               store
             )

    assert has_element?(view, card <> "[data-command-state=answered] .decision-answer-summary", "Yes")
    refute has_element?(view, card <> " form")
  end

  defp footer do
    {:ok, page, _} = live(build_conn(), "/")
    footer = find_live_child(page, "executor-footer-live")
    render_async(footer, 3_000)
    footer
  end

  defp request(store, key) do
    assert {:ok, %{decision: decision}} =
             DecisionStore.request(
               %{"source_id" => key, "question" => "Continue #{key}?", "blocking" => false, "reversibility" => "reversible", "options" => [%{"id" => "yes", "label" => "Yes"}]},
               [
                 ticket: %{identifier: "executor"},
                 source: %{agent_id: "executor", session_id: "executor-session"},
                 requester: %{kind: :executor, executor_id: "operator"},
                 origin: :executor_cli
               ],
               store
             )

    decision
  end
end
