defmodule Aiur.OperatorRelayAnswerTest do
  use ExUnit.Case, async: false
  require Phoenix.LiveViewTest
  import ExUnit.CaptureIO
  alias Aiur.{CommandsCLI, Config, Decision, DecisionAnswer, DecisionDispatch, DecisionHistory, DecisionStore, OperatorRelayCLI, Workflow}

  alias AiurWeb.ControlCenterPresenter
  alias AiurWeb.OperatorControlCenter.{DecisionCard, DecisionPresenter, History}

  setup do
    dir = Aiur.TestSupport.tmp_root!("operator-relay-3005")
    File.mkdir_p!(dir)
    config = Path.join(dir, "config")
    previous_env = Map.new([:workflow_file_path, :runtime_state_dir, :decision_state_dir, :log_file], &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :runtime_state_dir, dir)
    Application.put_env(:aiur, :decision_state_dir, dir)
    Application.put_env(:aiur, :log_file, Path.join(dir, "daemon.log"))
    File.write!(config, "tracker: {kind: memory}\nworkspace: {root: #{Path.join(dir, "workspaces")}}\nexecutor: {relay_operator_answers: false}\n")
    Workflow.set_workflow_file_path(config)

    on_exit(fn ->
      Workflow.clear_workflow_file_path()

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir, config: config}
  end

  defp enable(config) do
    File.write!(config, String.replace(File.read!(config), "relay_operator_answers: false", "relay_operator_answers: true"))
    Workflow.set_workflow_file_path(config)
    assert Config.relay_operator_answers?()
  end

  defp store(dir, opts \\ []) do
    start_supervised!({DecisionStore, Keyword.merge([name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000], opts)})
  end

  defp request(store, reversibility \\ "irreversible") do
    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{
          question: "Keep the palette?",
          authority: "human_required",
          reversibility: reversibility,
          blocking: true,
          source_id: "relay-palette",
          options: [%{id: "keep", label: "Keep them"}, %{id: "replace", label: "Replace them"}]
        },
        [ticket: %{identifier: "3005", title: "Relay test", url: nil}, source: %{agent_id: "codex", session_id: "relay-test"}],
        store
      )

    decision
  end

  defp params(decision) do
    [decision_id: decision.decision_id, expected_version: 1, option_id: "keep", quote: "  keep them\n", relayed_by: "attended-executor", idempotency_key: "palette-human-v1"]
  end

  defp relay(decision, store, overrides \\ []) do
    capture_io(fn ->
      assert OperatorRelayCLI.answer(Keyword.merge(params(decision), overrides), decision_store: store) == 0
    end)
  end

  test "human-only relay is rejected while disabled and enabled recording survives restart with exact provenance", %{dir: dir, config: config} do
    store = store(dir)
    decision = request(store, "reversible")
    refute Config.relay_operator_answers?()
    errors = capture_io(:stderr, fn -> assert OperatorRelayCLI.answer(params(decision), decision_store: store) == 1 end)
    assert errors =~ "operator must enable executor.relay_operator_answers"
    assert {:ok, %{answer: nil, decision_status: :open}} = DecisionStore.get(decision.decision_id, store)
    enable(config)
    # Existing Executor authority floor, retained as a future-regression guard.
    floor_error =
      capture_io(:stderr, fn ->
        assert Aiur.ExecutorCommandCLI.answer([decision_id: decision.decision_id, expected_version: 1, option_id: "keep", rationale: "Seemed obvious", idempotency_key: "executor-before-relay"],
                 decision_store: store
               ) == 1
      end)

    assert floor_error =~ "outside what the Executor may answer directly"
    assert floor_error =~ "human_required"
    assert relay(decision, store) =~ "answered by operator, relayed by attended-executor"
    assert {:ok, %{answer: answer}} = DecisionStore.get(decision.decision_id, store)
    assert answer.actor == %{kind: :operator_relayed, id: "attended-executor"}
    assert answer.operator_quote == "  keep them\n"
    assert answer.relayed_by == "attended-executor"
    assert %DateTime{} = answer.accepted_at
    assert answer.selected_option_id == "keep"
    stop_supervised!(DecisionStore)
    restarted = store(dir)
    assert {:ok, %{answer: ^answer}} = DecisionStore.get(decision.decision_id, restarted)
    assert {:ok, ^answer} = answer |> DecisionAnswer.to_json_safe() |> DecisionAnswer.from_json_safe()
  end

  test "relay supersede and revision cannot replace a direct operator answer", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    operator = %{kind: :operator, id: "dashboard"}
    payload = %{expected_version: 1, option_id: "keep", idempotency_key: "direct-operator"}
    assert {:ok, %{decision: original}} = DecisionStore.answer(decision.decision_id, payload, [actor: operator], store)

    errors =
      capture_io(:stderr, fn ->
        assert OperatorRelayCLI.answer(Keyword.merge(params(decision), supersede: true, option_id: "replace", quote: "fabricated", idempotency_key: "relay-overwrite"), decision_store: store) == 1
      end)

    assert errors =~ "operator_answer_present"

    revision = %{
      expected_version: 1,
      expected_action_id: original.active_action_id,
      expected_revision_sequence: 0,
      option_id: "replace",
      operator_quote: "fabricated",
      relayed_by: "attended-executor",
      idempotency_key: "relay-revision",
      rationale: "Relayed correction"
    }

    actor = %{kind: :operator_relayed, id: "attended-executor"}
    assert {:error, {:answer_invalid, {:operator_relay, :operator_answer_present}}} = DecisionStore.revise(decision.decision_id, revision, [actor: actor], store)
    assert {:ok, ^original} = DecisionStore.get(decision.decision_id, store)

    correction = %{expected_version: 1, option_id: "replace", idempotency_key: "operator-revision", rationale: "Operator changed direction"}
    assert {:ok, %{decision: revised}} = DecisionStore.supersede(decision.decision_id, correction, [actor: operator], store)
    assert Decision.active_answer(revised).actor == operator
    assert Decision.active_answer(revised).selected_option_id == "replace"
    assert revised.answer == original.answer
  end

  test "relay schedules the ordinary worker delivery with the chosen answer and relay correlation", %{dir: dir, config: config} do
    enable(config)
    parent = self()

    dispatcher = fn decision, opts ->
      DecisionDispatch.dispatch(
        decision,
        Keyword.put(opts, :send_fun, fn _server, ticket, payload ->
          send(parent, {:worker_delivery, ticket, payload})
          {:ok, %{status: :accepted, item: %{id: 3005}}}
        end)
      )
    end

    store = store(dir, dispatch_delay_ms: 0, dispatcher: dispatcher)
    decision = request(store)
    relay(decision, store)
    assert_receive {:worker_delivery, "3005", payload}, 3_000
    assert payload.body =~ "Selected option `keep`: Keep them"
    assert payload.correlation.actor == %{kind: :operator_relayed, id: "attended-executor"}
    assert payload.correlation.decision_id == decision.decision_id
    assert payload.delivery_policy == :interrupt
  end

  test "an operator supersedes or moots a relayed human-only answer through existing flows", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    relay(decision, store)
    assert {:ok, original} = DecisionStore.get(decision.decision_id, store)
    payload = %{expected_version: 1, option_id: "replace", rationale: "I changed my mind", idempotency_key: "operator-correction"}
    assert {:ok, %{decision: revised}} = DecisionStore.supersede(decision.decision_id, payload, [actor: %{kind: :operator, id: "dashboard"}], store)
    active = Decision.active_answer(revised)
    assert active.actor.kind == :operator
    assert active.selected_option_id == "replace"
    assert revised.answer == original.answer
    assert active.action_id != original.answer.action_id

    assert {:ok, %{decision: mooted}} =
             DecisionStore.moot(decision.decision_id, %{expected_version: 1, reason_class: "operator_changed_direction"}, [actor: %{kind: :operator, id: "dashboard"}], store)

    assert mooted.decision_status == :moot
  end

  test "the CLI relays an operator correction as a custom response with a fresh alert", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    relay(decision, store)

    corrected =
      params(decision)
      |> Keyword.delete(:option_id)
      |> Keyword.merge(custom_response: "Use a neutral palette", quote: "use neutral colors instead", supersede: true, idempotency_key: "palette-human-v2")

    capture_io(fn -> assert OperatorRelayCLI.answer(corrected, decision_store: store) == 0 end)
    {:ok, revised} = DecisionStore.get(decision.decision_id, store)
    active = Decision.active_answer(revised)
    assert active.custom_response == "Use a neutral palette"
    assert active.actor.kind == :operator_relayed
    assert active.operator_quote == "use neutral colors instead"
    assert revised.answer.operator_quote == "  keep them\n"
    notices = Enum.filter(Aiur.AlertFeed.list(roots: [], log_roots: [dir]), &(&1["topic"] == "executor.command.operator_relayed"))
    assert length(notices) == 2
  end

  test "relay retry is idempotent, quote conflicts are rejected and disabling prevents new relays", %{dir: dir, config: config} do
    enable(config)
    parent = self()
    store = store(dir, relay_notifier: fn decision, answer -> send(parent, {:relay_notice, decision.decision_id, answer.operator_quote, answer.relayed_by}) end)
    decision = request(store)
    relay(decision, store)
    assert_receive {:relay_notice, id, "  keep them\n", "attended-executor"}, 1_000
    assert id == decision.decision_id
    assert relay(decision, store) =~ "duplicate"
    refute_received {:relay_notice, _, _, _}
    errors = capture_io(:stderr, fn -> assert OperatorRelayCLI.answer(Keyword.put(params(decision), :quote, "replace them"), decision_store: store) == 1 end)
    assert errors =~ "idempotency_conflict"
    File.write!(config, String.replace(File.read!(config), "relay_operator_answers: true", "relay_operator_answers: false"))
    Workflow.set_workflow_file_path(config)
    errors = capture_io(:stderr, fn -> assert OperatorRelayCLI.answer(params(decision), decision_store: store) == 1 end)
    assert errors =~ "operator must enable executor.relay_operator_answers"
    # Existing floor, deliberately retained as a future-regression guard.
    payload = %{expected_version: 1, option_id: "keep", rationale: "Already decided", idempotency_key: "executor-try"}
    assert {:error, {:answer_invalid, {:executor_scope, {:authority, :human_required}}}} = DecisionStore.answer(decision.decision_id, payload, [actor: %{kind: :executor, id: "executor"}], store)
  end

  test "relay quote and relayer are required at the serialized boundary", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    payload = %{expected_version: 1, option_id: "keep", idempotency_key: "bad-relay"}
    actor = [actor: %{kind: :operator_relayed, id: "executor"}]
    assert {:error, {:answer_invalid, {:relayed_by, :missing}}} = DecisionStore.answer(decision.decision_id, payload, actor, store)
    assert {:error, {:answer_invalid, {:operator_quote, :missing}}} = DecisionStore.answer(decision.decision_id, Map.put(payload, :relayed_by, "executor"), actor, store)
  end

  test "accepted relay emits an info alert naming the Command, quote and relayer", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    relay(decision, store)
    [notice] = Enum.filter(Aiur.AlertFeed.list(roots: [], log_roots: [dir]), &(&1["topic"] == "executor.command.operator_relayed"))
    assert notice["severity"] == "info"
    assert notice["needs_attention"] == false
    assert notice["message"] =~ decision.decision_id
    assert notice["message"] =~ "attended-executor"
    assert notice["message"] =~ "  keep them\n"
  end

  test "dashboard card and timeline render the canonical relay attribution and quote", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    relay(decision, store)
    {:ok, recorded} = DecisionStore.get(decision.decision_id, store)
    [row] = DecisionPresenter.present(recorded)
    history = ControlCenterPresenter.compose(%{}, [recorded], DecisionHistory.list(server: store), %{}).history

    html =
      Phoenix.LiveViewTest.render_component(
        &DecisionCard.decision_card/1,
        %{decision: row, history: history, writable: false, selected: true, now: DateTime.utc_now()}
      )

    card_html =
      Phoenix.LiveViewTest.render_component(
        &DecisionCard.decision_card/1,
        %{decision: row, writable: false, now: DateTime.utc_now()}
      )

    assert card_html =~ "answered by operator, relayed by attended-executor"
    assert html =~ "answered by operator, relayed by attended-executor"
    assert html =~ "Operator quote:   keep them"

    history_html =
      Phoenix.LiveViewTest.render_component(
        &History.history/1,
        %{rows: [row], loaded: 1, total: 1}
      )

    assert history_html =~ "answered by operator, relayed by attended-executor"
    refute history_html =~ ">Operator answer<"
    refute html =~ ">Operator answer<"
    refute html =~ ">Executor answer<"
  end

  test "Command detail and history expose relayed attribution and quote", %{dir: dir, config: config} do
    enable(config)
    store = store(dir)
    decision = request(store)
    relay(decision, store)
    output = capture_io(fn -> assert CommandsCLI.run(decision_id: decision.decision_id, decision_store: store) == 0 end)
    assert output =~ "answered by operator, relayed by attended-executor"
    assert output =~ "Operator quote:   keep them\n"
    [answered] = Enum.filter(DecisionHistory.list(server: store), &(&1.change == :answered))
    assert answered.actor.type == :operator_relayed
    assert answered.operator_quote == "  keep them\n"
  end
end
