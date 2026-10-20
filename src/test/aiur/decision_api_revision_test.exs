defmodule Aiur.DecisionApiRevisionTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionApi, DecisionStore}

  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}

  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

  setup_all do: :ok = Aiur.TestSupport.ensure_runtime_children_running()

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-api")
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

  test "revise delegates to OCC-8 with trusted actor and policy basis", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "revise")

    assert {:ok, %{action: original}} =
             DecisionStore.answer(
               decision.decision_id,
               %{
                 "expected_version" => 1,
                 "idempotency_key" => "original-answer",
                 "custom_response" => "Use the original path",
                 "rationale" => "Initial evidence"
               },
               [actor: %{kind: :operator, id: "operator-1"}, now: ~U[2026-07-12 10:30:00Z]],
               store
             )

    payload = revision_payload(original)
    opts = supervisor_opts(store)

    assert {:ok, result} = DecisionApi.revise(decision.decision_id, payload, opts)
    assert result["status"] == "accepted"
    assert result["revision_result"] == "recorded"
    assert result["action"]["prior_action_id"] == original.action_id
    assert result["action"]["answer"]["actor"] == %{"kind" => "supervisor", "id" => "supervising-agent"}

    basis = result["action"]["answer"]["supervisor_basis"]
    assert basis["confidence"] == 88
    assert basis["policy_basis"]["authority"] == "supervisor_allowed"
    assert basis["policy_basis"]["checks"]["kind_allowed"]

    assert {:ok, replay} = DecisionApi.revise(decision.decision_id, payload, opts)
    assert replay["status"] == "duplicate"
    assert replay["action"]["action_id"] == result["action"]["action_id"]

    assert {:error, {:conflict, {:idempotency_conflict, _action_id}}} =
             DecisionApi.revise(
               decision.decision_id,
               Map.put(payload, "custom_response", "Conflicting correction"),
               opts
             )

    stale =
      payload
      |> Map.put("idempotency_key", "revise-stale")
      |> Map.put("custom_response", "Another correction")

    assert {:error, {:conflict, {:stale_action, _correlation}}} =
             DecisionApi.revise(decision.decision_id, stale, opts)

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%Aiur.DecisionEvent{type: :revision_recorded}, &1)) == 1
  end

  test "the API keeps confidence endpoints as integer supervisor basis values", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "confidence-boundaries")

    answer_payload =
      decision_payload()
      |> Map.put("idempotency_key", "confidence-zero")
      |> Map.put("confidence", 0)

    assert {:ok, answered} = DecisionApi.decide(decision.decision_id, answer_payload, supervisor_opts(store))
    assert answered["action"]["supervisor_basis"]["confidence"] == 0

    revision_payload = %{
      "expected_version" => 1,
      "expected_action_id" => answered["action"]["action_id"],
      "expected_revision_sequence" => 0,
      "idempotency_key" => "confidence-hundred",
      "custom_response" => "Use the corrected path",
      "rationale" => "New production evidence",
      "confidence" => 100,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }

    assert {:ok, revised} = DecisionApi.revise(decision.decision_id, revision_payload, supervisor_opts(store))
    assert revised["action"]["answer"]["supervisor_basis"]["confidence"] == 100

    assert {:ok, current} = DecisionStore.get(decision.decision_id, store)
    assert current.answer.supervisor_basis.confidence == 0
    assert hd(current.revisions).answer.supervisor_basis.confidence == 100
  end

  test "revise denies unsafe, forged, or incomplete calls before OCC-8 persistence", %{store: store} do
    human = request!(store, "architecture", :human_required, source_id: "revise-human")

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.revise(human.decision_id, %{}, supervisor_opts(store))

    eligible = request!(store, "architecture", :supervisor_allowed, source_id: "revise-eligible")

    assert {:error, {:delegation_invalid, {:forbidden_fields, ["actor", "authority"]}}} =
             DecisionApi.revise(
               eligible.decision_id,
               %{"actor" => %{}, "authority" => "human_required"},
               supervisor_opts(store)
             )

    incomplete =
      %{
        "expected_version" => 1,
        "expected_action_id" => "act_original",
        "expected_revision_sequence" => 0,
        "idempotency_key" => "revision-incomplete",
        "custom_response" => "Corrected",
        "rationale" => "New evidence",
        "alternatives_considered" => [],
        "reversibility_belief" => "reversible"
      }

    assert {:error, {:delegation_invalid, {:confidence, :invalid}}} =
             DecisionApi.revise(eligible.decision_id, incomplete, supervisor_opts(store))
  end

  test "an unavailable store is a stable read error", %{store: store} do
    GenServer.stop(store)

    assert {:error, :store_unavailable} = DecisionApi.list(%{}, store: store, policy: @policy)
    assert {:error, :store_unavailable} = DecisionApi.get("dec_missing", store: store, policy: @policy)

    assert {:error, :store_unavailable} =
             DecisionApi.enrich(
               "dec_missing",
               %{"expected_version" => 1, "context" => %{"short_summary" => "No store"}},
               store: store,
               actor: %{kind: :supervisor, id: "supervising-agent"}
             )

    assert {:error, :store_unavailable} =
             DecisionApi.decide("dec_missing", decision_payload(), supervisor_opts(store))

    assert {:error, :store_unavailable} =
             DecisionApi.revise("dec_missing", %{}, supervisor_opts(store))
  end

  defp decision_payload do
    %{
      "idempotency_key" => "supervisor-decide-1",
      "expected_version" => 1,
      "custom_response" => "Use the canonical path",
      "rationale" => "It preserves one append-only lifecycle.",
      "confidence" => 91,
      "alternatives_considered" => ["Wait for OCC-8"],
      "reversibility_belief" => "reversible"
    }
  end

  defp revision_payload(original) do
    %{
      "expected_version" => 1,
      "expected_action_id" => original.action_id,
      "expected_revision_sequence" => 0,
      "idempotency_key" => "supervisor-revision-1",
      "custom_response" => "Use the corrected path",
      "rationale" => "New production evidence",
      "confidence" => 88,
      "alternatives_considered" => ["Keep the original direction"],
      "reversibility_belief" => "reversible"
    }
  end

  defp supervisor_opts(store) do
    [
      store: store,
      policy: @policy,
      actor: %{kind: :supervisor, id: "supervising-agent"},
      now: ~U[2026-07-12 11:00:00Z]
    ]
  end

  defp request!(store, kind, authority, opts) do
    source_id = Keyword.fetch!(opts, :source_id)
    now = Keyword.get(opts, :now, ~U[2026-07-12 10:00:00Z])
    blocking = Keyword.get(opts, :blocking, true)

    payload = %{
      "source_id" => source_id,
      "question" => "Choose #{source_id}?",
      "blocking" => blocking,
      "kind" => kind,
      "authority" => Atom.to_string(authority),
      "context" => if(authority == :human_required, do: %{"authority_basis" => if(kind == "product", do: "product", else: "security")}, else: nil),
      "reversibility" => "reversible"
    }

    payload =
      case Keyword.get(opts, :version) do
        nil -> payload
        version -> Map.put(payload, "version", version)
      end

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end
end
