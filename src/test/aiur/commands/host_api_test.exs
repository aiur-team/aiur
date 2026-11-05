defmodule Aiur.Commands.HostApiTest do
  use ExUnit.Case, async: false

  alias Aiur.Commands.{HostApi, Scope}
  alias Aiur.{DecisionQuery, DecisionStore}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @secret String.duplicate("s", 64)
  @now ~U[2026-11-05 12:00:00Z]

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-host-api")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} = DecisionStore.start_link(name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "list returns only Commands for the allowed ticket set", %{store: store} do
    allowed = request!(store, "42", "allowed")
    _other = request!(store, "99", "out-of-scope")

    scope = scope_for(["42"])
    events = []

    assert {:ok, page} = HostApi.list(scope, %{}, store: store, events: events)
    assert page["count"] == 1
    assert [command] = page["commands"]
    assert command["decision_id"] == allowed.decision_id
    assert command["state"] == "pending"
    assert command["ticket"]["identifier"] == "42"

    assert page["scope"] == %{"kind" => "tickets", "label" => "Ticket-scoped Commands", "tickets" => ["42"]}

    # The count describes the allowed ticket set only; it never hints at the
    # out-of-scope Command.
    assert page["pagination"]["total"] == 1
    refute inspect(page) =~ "out-of-scope"
  end

  test "listing a ticket outside the set is empty, not an error that reveals it", %{store: store} do
    _allowed = request!(store, "42", "allowed")
    _other = request!(store, "99", "out-of-scope")

    scope = scope_for(["42"])

    assert {:ok, page} = HostApi.list(scope, %{"ticket" => "99"}, store: store)
    assert page["commands"] == []
    assert page["count"] == 0
    assert page["pagination"]["total"] == 0
  end

  test "show and answer treat an out-of-scope Command as not found", %{store: store} do
    out_of_scope = request!(store, "99", "hidden")

    scope = scope_for(["42"])

    assert {:error, :not_found} = HostApi.show(scope, out_of_scope.decision_id, store: store)

    assert {:error, :not_found} =
             HostApi.answer(scope, out_of_scope.decision_id, answer_payload(out_of_scope.version, "approve"), store: store)

    assert {:ok, %{decision: unchanged}} = DecisionQuery.get(out_of_scope.decision_id, store: store)
    assert unchanged.answer == nil
    assert unchanged.decision_status == :open

    # A guessed identifier that does not exist answers identically.
    assert {:error, :not_found} = HostApi.show(scope, "dec_guessed", store: store)
  end

  test "an allowed pending Command is answered through the canonical human-answer path", %{store: store} do
    decision = request!(store, "42", "allowed")
    scope = scope_for(["42"])

    assert {:ok, %{"command" => command}} =
             HostApi.answer(scope, decision.decision_id, answer_payload(decision.version, "approve"), store: store)

    assert command["state"] == "answered"
    assert command["answer"]["selected_option_id"] == "approve"

    assert {:ok, %{decision: answered}} = DecisionQuery.get(decision.decision_id, store: store)
    assert answered.decision_status == :decided
    assert answered.answer.actor.kind == :operator
    assert answered.answer.actor.id == "player-7"
    assert answered.answer.actor.source == :host_api
    assert answered.answer.selected_option_id == "approve"
  end

  test "a free-response answer is recorded with the caller's text", %{store: store} do
    decision = request!(store, "42", "allowed", options: [])
    scope = scope_for(["42"])

    payload = %{
      "idempotency_key" => "submit-free",
      "expected_version" => decision.version,
      "custom_response" => "Ship it once the tests are green."
    }

    assert {:ok, %{"command" => command}} = HostApi.answer(scope, decision.decision_id, payload, store: store)
    assert command["state"] == "answered"

    assert {:ok, %{decision: answered}} = DecisionQuery.get(decision.decision_id, store: store)
    assert answered.answer.custom_response == "Ship it once the tests are green."
  end

  test "a stale expected version is a conflict with the current version", %{store: store} do
    decision = request!(store, "42", "allowed")
    scope = scope_for(["42"])

    assert {:ok, %{"command" => command}} =
             HostApi.answer(scope, decision.decision_id, answer_payload(decision.version + 1, "approve"), store: store)

    assert command["state"] == "conflict"
    assert command["reason"] == "stale_version"
    assert command["version"] == decision.version
  end

  test "a duplicate submit is idempotent and a second answer is a conflict", %{store: store} do
    decision = request!(store, "42", "allowed")
    scope = scope_for(["42"])
    payload = answer_payload(decision.version, "approve")

    assert {:ok, %{"command" => first}} = HostApi.answer(scope, decision.decision_id, payload, store: store)
    assert first["state"] == "answered"
    assert first["reason"] == nil

    assert {:ok, %{"command" => replay}} = HostApi.answer(scope, decision.decision_id, payload, store: store)
    assert replay["state"] == "answered"
    assert replay["reason"] == "duplicate_submit"

    changed =
      payload
      |> Map.put("idempotency_key", "another-submit")

    assert {:ok, %{"command" => conflict}} = HostApi.answer(scope, decision.decision_id, changed, store: store)
    assert conflict["state"] == "conflict"
  end

  test "a missing idempotency key or expected version is rejected before the store", %{store: store} do
    decision = request!(store, "42", "allowed")
    scope = scope_for(["42"])

    assert {:error, {:invalid_answer, {:idempotency_key, :missing}}} =
             HostApi.answer(scope, decision.decision_id, %{"expected_version" => decision.version}, store: store)

    assert {:error, {:invalid_answer, {:expected_version, :invalid}}} =
             HostApi.answer(scope, decision.decision_id, %{"idempotency_key" => "key"}, store: store)

    assert {:ok, %{decision: unchanged}} = DecisionQuery.get(decision.decision_id, store: store)
    assert unchanged.answer == nil
  end

  test "an unknown option keeps the Command open and reports validation failure", %{store: store} do
    decision = request!(store, "42", "allowed")
    scope = scope_for(["42"])

    assert {:ok, %{"command" => command}} =
             HostApi.answer(scope, decision.decision_id, answer_payload(decision.version, "nope"), store: store)

    assert command["state"] == "error"
    assert command["reason"] == "validation_failed"

    assert {:ok, %{decision: unchanged}} = DecisionQuery.get(decision.decision_id, store: store)
    assert unchanged.answer == nil
  end

  test "the answered Command still carries its options, recommendation and media", %{store: store} do
    decision = request!(store, "42", "allowed")
    scope = scope_for(["42"])

    assert {:ok, %{"command" => command}} =
             HostApi.answer(scope, decision.decision_id, answer_payload(decision.version, "approve"), store: store)

    assert Enum.map(command["options"], & &1["id"]) == ["approve", "hold"]
    assert command["recommendation"]["option_id"] == "approve"
    assert command["media"] == [%{"kind" => "url", "value" => "https://github.com/aiur-team/aiur/issues/42"}]
  end

  test "a label-scoped grant lists only Commands on tickets carrying the label", %{store: store} do
    labelled = request!(store, "42", "labelled")
    _other = request!(store, "99", "other-game")

    scope = label_scope(["game:chess"])
    labels_fun = fn -> {:ok, %{"42" => %{labels: ["game:chess", "area:play"]}, "99" => %{labels: ["game:checkers"]}}, 0} end

    assert {:ok, page} = HostApi.list(scope, %{}, store: store, labels_fun: labels_fun)
    assert page["count"] == 1
    assert [command] = page["commands"]
    assert command["decision_id"] == labelled.decision_id
    assert command["ticket"]["identifier"] == "42"
    assert page["scope"]["labels"] == ["game:chess"]
    refute inspect(page) =~ "other-game"
  end

  test "show and answer refuse an unlabelled ticket for a label-only grant", %{store: store} do
    unlabelled = request!(store, "99", "other-game")
    scope = label_scope(["game:chess"])
    labels_fun = fn -> {:ok, %{"99" => %{labels: ["game:checkers"]}}, 0} end

    assert {:error, :not_found} =
             HostApi.show(scope, unlabelled.decision_id, store: store, labels_fun: labels_fun)

    assert {:error, :not_found} =
             HostApi.answer(scope, unlabelled.decision_id, answer_payload(unlabelled.version, "approve"),
               store: store,
               labels_fun: labels_fun
             )

    assert {:ok, %{decision: unchanged}} = DecisionQuery.get(unlabelled.decision_id, store: store)
    assert unchanged.answer == nil
    assert unchanged.decision_status == :open
  end

  test "explicit tickets and a label scope combine", %{store: store} do
    explicit = request!(store, "42", "explicit")
    labelled = request!(store, "43", "labelled")
    outside = request!(store, "99", "outside")

    scope = label_scope(["game:chess"], ["42"])
    labels_fun = fn -> {:ok, %{"43" => %{labels: ["game:chess"]}, "99" => %{labels: ["game:other"]}}, 0} end

    assert {:ok, page} = HostApi.list(scope, %{}, store: store, labels_fun: labels_fun)

    assert Enum.sort(Enum.map(page["commands"], & &1["decision_id"])) ==
             Enum.sort([explicit.decision_id, labelled.decision_id])

    assert {:ok, _} = HostApi.show(scope, explicit.decision_id, store: store, labels_fun: labels_fun)
    assert {:error, :not_found} = HostApi.show(scope, outside.decision_id, store: store, labels_fun: labels_fun)
  end

  test "a label scope fails closed without a usable label observation", %{store: store} do
    decision = request!(store, "42", "labelled")
    scope = label_scope(["game:chess"])

    assert {:ok, page} = HostApi.list(scope, %{}, store: store, labels_fun: fn -> :none end)
    assert page["commands"] == []
    assert page["count"] == 0

    assert {:error, :not_found} =
             HostApi.show(scope, decision.decision_id, store: store, labels_fun: fn -> {:error, :unsupported} end)

    assert {:error, :not_found} =
             HostApi.answer(scope, decision.decision_id, answer_payload(decision.version, "approve"),
               store: store,
               labels_fun: fn -> :none end
             )

    assert {:ok, %{decision: unchanged}} = DecisionQuery.get(decision.decision_id, store: store)
    assert unchanged.answer == nil
  end

  defp label_scope(labels, tickets \\ []) do
    {:ok, %{scope: scope}} = Scope.mint("player-7", tickets, secret: @secret, now: @now, labels: labels)
    scope
  end

  defp scope_for(tickets) do
    {:ok, %{scope: scope}} = Scope.mint("player-7", tickets, secret: @secret, now: @now)
    scope
  end

  defp answer_payload(version, option_id) do
    %{
      "idempotency_key" => "submit-#{System.unique_integer([:positive])}",
      "expected_version" => version,
      "option_id" => option_id
    }
  end

  defp request!(store, ticket, source_id, opts \\ []) do
    options =
      case Keyword.get(opts, :options) do
        nil ->
          [
            %{"id" => "approve", "label" => "Approve", "description" => "Ship it"},
            %{"id" => "hold", "label" => "Hold"}
          ]

        options ->
          options
      end

    payload = %{
      "source_id" => source_id,
      "question" => "What should we do about #{source_id}?",
      "blocking" => true,
      "kind" => "architecture",
      "authority" => "supervisor_allowed",
      "reversibility" => "reversible",
      "options" => options,
      "recommendation" => if(options == [], do: nil, else: %{"option_id" => "approve"}),
      "artifacts" => ["https://github.com/aiur-team/aiur/issues/42"]
    }

    ticket_map = %{
      identifier: ticket,
      title: "Ticket #{ticket}",
      url: "https://example.test/issues/#{ticket}"
    }

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: ticket_map, source: @source, now: @now], store)

    decision
  end
end
