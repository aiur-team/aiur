defmodule Aiur.DecisionApiTest do
  use ExUnit.Case, async: false

  alias Aiur.{DecisionApi, DecisionDelegation, DecisionStore}

  @ticket %{identifier: "984", title: "OCC-7", url: "https://github.com/its-everdred/aiur/issues/984"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}
  @policy %{allowed_kinds: ["architecture"], allow_non_reversible: false}

  setup do
    original_override = Application.get_env(:aiur, :decision_state_dir)
    dir = Path.join(System.tmp_dir!(), "aiur-decision-api-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :decision_state_dir, dir)

    {:ok, store} =
      DecisionStore.start_link(
        name: nil,
        filesystem_sync_fun: fn -> :ok end
      )

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)

      case original_override do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      File.rm_rf!(dir)
    end)

    %{store: store}
  end

  test "list returns deterministic canonical projections with current policy evaluation", %{store: store} do
    older =
      request!(store, "architecture", :supervisor_allowed,
        source_id: "older",
        now: ~U[2026-07-12 10:00:00Z]
      )

    newer =
      request!(store, "product", :human_required,
        source_id: "newer",
        now: ~U[2026-07-12 11:00:00Z]
      )

    assert {:ok, payload} =
             DecisionApi.list(%{"limit" => "1", "offset" => "0"}, store: store, policy: @policy)

    assert payload["pagination"] == %{"limit" => 1, "next_offset" => 1, "offset" => 0, "total" => 2}
    assert [encoded] = payload["decisions"]
    assert encoded["decision_id"] == newer.decision_id
    assert encoded["question"] == newer.question
    assert encoded["supervisor_policy"]["allowed"] == false
    assert encoded["supervisor_policy"]["reasons"] == ["human_required", "kind_not_allowed"]

    assert {:ok, second_page} =
             DecisionApi.list(%{limit: 1, offset: 1}, store: store, policy: @policy)

    assert second_page["pagination"]["next_offset"] == nil
    assert [encoded_older] = second_page["decisions"]
    assert encoded_older["decision_id"] == older.decision_id
    assert encoded_older["supervisor_policy"]["allowed"]

    refute Map.has_key?(encoded_older["supervisor_policy"], "allowed_kinds")
  end

  test "list validates and applies only the documented filters", %{store: store} do
    architecture =
      request!(store, "Architecture", :supervisor_preferred,
        source_id: "architecture",
        blocking: true
      )

    _product =
      request!(store, "product", :human_required,
        source_id: "product",
        blocking: false
      )

    filters = %{
      "authority" => "supervisor_preferred",
      "blocking" => "true",
      "kind" => "architecture",
      "ticket" => "984"
    }

    assert {:ok, %{"decisions" => [encoded], "pagination" => %{"total" => 1}}} =
             DecisionApi.list(filters, store: store, policy: @policy)

    assert encoded["decision_id"] == architecture.decision_id
  end

  test "malformed or unknown list parameters fail rather than broadening the result", %{store: store} do
    request!(store, "architecture", :supervisor_allowed, source_id: "one")

    invalid_params = [
      %{"limit" => 0},
      %{"limit" => 201},
      %{"offset" => -1},
      %{"blocking" => "yes"},
      %{"authority" => "future"},
      %{"ticket" => ""},
      %{"unknown" => "ignored"},
      %{"kind" => "architecture", kind: "product"},
      []
    ]

    for params <- invalid_params do
      assert {:error, {:invalid_list, _reason}} =
               DecisionApi.list(params, store: store, policy: @policy)
    end

    assert length(DecisionStore.list(store)) == 1
  end

  test "get returns one canonical projection and preserves not-found", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "known")

    assert {:ok, encoded} = DecisionApi.get(decision.decision_id, store: store, policy: @policy)
    assert encoded["decision_id"] == decision.decision_id
    assert encoded["supervisor_policy"]["allowed"]

    assert {:error, :not_found} = DecisionApi.get("dec_missing", store: store, policy: @policy)
    assert {:error, {:invalid_decision_id, :missing}} = DecisionApi.get("   ", store: store, policy: @policy)

    assert {:error, {:invalid_decision_id, :too_long}} =
             DecisionApi.get(String.duplicate("a", 257), store: store, policy: @policy)
  end

  test "enrich delegates a constrained attributed version to the canonical store", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "enrich")

    payload = %{
      "expected_version" => 1,
      "context" => %{"short_summary" => "Canonical context"}
    }

    opts = [
      store: store,
      policy: @policy,
      actor: %{kind: :supervisor, id: "supervising-agent"},
      now: ~U[2026-07-12 11:00:00Z]
    ]

    assert {:ok, %{"status" => "accepted", "decision" => enriched}} =
             DecisionApi.enrich(decision.decision_id, payload, opts)

    assert enriched["version"] == 2
    assert enriched["context"]["short_summary"] == "Canonical context"
    assert enriched["supervisor_policy"]["allowed"]

    assert {:ok, %{"status" => "duplicate", "decision" => duplicate}} =
             DecisionApi.enrich(decision.decision_id, payload, opts)

    assert duplicate["version"] == 2
  end

  test "enrich rejects untrusted actor claims and malformed correlation", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "enrich-invalid")

    opts = [
      store: store,
      policy: @policy,
      actor: %{kind: :supervisor, id: "supervising-agent"}
    ]

    assert {:error, {:enrichment_invalid, {:forbidden_fields, ["actor"]}}} =
             DecisionApi.enrich(
               decision.decision_id,
               %{"expected_version" => 1, "actor" => %{"kind" => "operator"}},
               opts
             )

    assert {:error, {:invalid_enrichment, {:expected_version, :invalid}}} =
             DecisionApi.enrich(decision.decision_id, %{"expected_version" => "1"}, opts)

    assert {:error, {:invalid_enrichment, {:expected_version, :duplicate}}} =
             DecisionApi.enrich(
               decision.decision_id,
               %{"expected_version" => 1, expected_version: 1},
               opts
             )

    assert {:error, {:invalid_enrichment, {:actor, :untrusted}}} =
             DecisionApi.enrich(
               decision.decision_id,
               %{"expected_version" => 1, "context" => %{"short_summary" => "No"}},
               Keyword.put(opts, :actor, %{kind: :operator, id: "operator-1"})
             )
  end

  test "decide snapshots supervisor reasoning and delegates exactly once to OCC-3", %{store: store} do
    decision = request!(store, "architecture", :supervisor_allowed, source_id: "decide")
    payload = decision_payload()
    opts = supervisor_opts(store)

    assert {:ok, result} = DecisionApi.decide(decision.decision_id, payload, opts)
    assert result["status"] == "accepted"
    assert result["dispatch_status"] == "dispatch_pending"
    assert result["decision"]["decision_status"] == "decided"

    basis = result["action"]["supervisor_basis"]
    assert basis["confidence"] == 91
    assert basis["alternatives_considered"] == ["Wait for OCC-8"]
    assert basis["reversibility_belief"] == "reversible"
    assert basis["policy_basis"]["authority"] == "supervisor_allowed"
    assert basis["policy_basis"]["checks"]["kind_allowed"]

    assert {:ok, replay} = DecisionApi.decide(decision.decision_id, payload, opts)
    assert replay["status"] == "duplicate"
    assert replay["action"]["action_id"] == result["action"]["action_id"]

    assert {:ok, audit} = DecisionStore.audit_history(decision.decision_id, store)
    assert Enum.count(audit, &match?(%Aiur.DecisionEvent{type: :answer_recorded}, &1)) == 1
  end

  test "decide denies unsafe policy or incomplete reasoning before answer persistence", %{store: store} do
    human = request!(store, "architecture", :human_required, source_id: "decide-human")

    assert {:error, {:delegation_forbidden, %{reasons: [:human_required]}}} =
             DecisionApi.decide(human.decision_id, decision_payload(), supervisor_opts(store))

    assert {:ok, audit} = DecisionStore.audit_history(human.decision_id, store)
    refute Enum.any?(audit, &match?(%Aiur.DecisionEvent{type: :answer_recorded}, &1))

    eligible = request!(store, "architecture", :supervisor_allowed, source_id: "decide-invalid")
    invalid = Map.delete(decision_payload(), "confidence")

    assert {:error, {:delegation_invalid, {:confidence, :invalid}}} =
             DecisionApi.decide(eligible.decision_id, invalid, supervisor_opts(store))

    forged = Map.put(decision_payload(), "actor", %{"kind" => "operator"})

    assert {:error, {:delegation_invalid, {:forbidden_fields, ["actor"]}}} =
             DecisionApi.decide(eligible.decision_id, forged, supervisor_opts(store))

    assert {:ok, current} = DecisionStore.get(eligible.decision_id, store)
    assert current.answer == nil
  end

  test "the serialized writer rejects supervisor basis from a different request version", %{store: store} do
    v1 = request!(store, "architecture", :supervisor_allowed, source_id: "policy-race")
    payload = Map.put(decision_payload(), "expected_version", 2)

    assert {:ok, delegation} = DecisionDelegation.normalize(v1, payload, @policy)

    assert {:ok, %{decision: v2}} =
             DecisionStore.request(
               %{
                 "version" => 2,
                 "source_id" => "policy-race",
                 "question" => "Choose policy-race?",
                 "blocking" => true,
                 "kind" => "architecture",
                 "authority" => "human_required",
                 "reversibility" => "reversible"
               },
               [ticket: @ticket, source: @source, now: ~U[2026-07-12 10:30:00Z]],
               store
             )

    assert v2.authority == :human_required

    assert {:error, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}} =
             DecisionStore.answer(
               v2.decision_id,
               delegation.answer_payload,
               [
                 actor: %{kind: :supervisor, id: "supervising-agent"},
                 supervisor_basis: delegation.basis,
                 now: ~U[2026-07-12 11:00:00Z]
               ],
               store
             )

    assert {:ok, current} = DecisionStore.get(v2.decision_id, store)
    assert current.answer == nil

    assert {:ok, %{action: original}} =
             DecisionStore.answer(
               v2.decision_id,
               %{
                 "expected_version" => 2,
                 "idempotency_key" => "policy-race-original",
                 "custom_response" => "Human direction",
                 "rationale" => "Operator chose the current version"
               },
               [actor: %{kind: :operator, id: "operator-1"}],
               store
             )

    revision_payload =
      original
      |> revision_payload()
      |> Map.put("expected_version", 2)

    assert {:ok, revision_delegation} =
             DecisionDelegation.normalize_revision(v1, revision_payload, @policy)

    assert {:error, {:revision_invalid, {:answer_invalid, {:supervisor_basis, :decision_mismatch}}}} =
             DecisionStore.revise(
               v2.decision_id,
               revision_delegation.answer_payload,
               [
                 actor: %{kind: :supervisor, id: "supervising-agent"},
                 supervisor_basis: revision_delegation.basis,
                 now: ~U[2026-07-12 11:01:00Z]
               ],
               store
             )

    assert {:ok, audit} = DecisionStore.audit_history(v2.decision_id, store)
    refute Enum.any?(audit, &match?(%Aiur.DecisionEvent{type: :revision_recorded}, &1))
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
      "reversibility" => "reversible"
    }

    assert {:ok, %{decision: decision}} =
             DecisionStore.request(payload, [ticket: @ticket, source: @source, now: now], store)

    decision
  end
end
