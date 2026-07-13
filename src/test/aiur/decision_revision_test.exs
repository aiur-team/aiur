defmodule Aiur.DecisionRevisionTest do
  use ExUnit.Case, async: true

  alias Aiur.{DecisionRevision, DecisionValidation}

  @decision_id "dec_revision_test"
  @decision_version 3
  @prior_action_id "act_original"
  @actor %{kind: :operator, id: "operator-1"}
  @now ~U[2026-07-12 12:00:00Z]

  describe "normalize/2" do
    test "records one ordered replacement linked to the active action" do
      assert {:ok, revision} = normalize(valid_payload())

      assert revision.decision_id == @decision_id
      assert revision.decision_version == @decision_version
      assert revision.sequence == 1
      assert revision.prior_action_id == @prior_action_id
      assert revision.action_id == "act_replacement"
      assert revision.reason == "Requirements changed"
      assert revision.recorded_at == @now
      assert revision.answer.actor == @actor
      assert is_binary(revision.content_hash)
    end

    test "rejects stale action correlation before normalizing the answer" do
      parent = self()
      answer_normalizer = fn _payload, _opts -> send(parent, :normalized_answer) end

      assert normalize(
               Map.put(valid_payload(), "expected_action_id", "act_stale"),
               answer_normalizer: answer_normalizer
             ) ==
               {:error, {:revision_invalid, {:stale_action, %{expected: "act_stale", current: @prior_action_id}}}}

      refute_receive :normalized_answer
    end

    test "rejects stale revision sequence before normalizing the answer" do
      parent = self()
      answer_normalizer = fn _payload, _opts -> send(parent, :normalized_answer) end

      assert normalize(
               Map.put(valid_payload(), "expected_revision_sequence", 2),
               answer_normalizer: answer_normalizer
             ) ==
               {:error, {:revision_invalid, {:stale_sequence, %{expected: 2, current: 0}}}}

      refute_receive :normalized_answer
    end

    test "requires the OCC-3 normalized answer to carry a revision reason" do
      answer_normalizer = fn _payload, opts ->
        {:ok, normalized_answer(opts, rationale: nil)}
      end

      assert normalize(valid_payload(), answer_normalizer: answer_normalizer) ==
               {:error, {:revision_invalid, {:reason, :missing}}}
    end

    test "rejects an idempotency key that resolves to the prior action" do
      answer_normalizer = fn _payload, opts ->
        {:ok, normalized_answer(opts, action_id: @prior_action_id)}
      end

      assert normalize(valid_payload(), answer_normalizer: answer_normalizer) ==
               {:error, {:revision_invalid, {:action_id, :unchanged}}}
    end

    test "propagates answer validation failures without accepting a revision" do
      answer_normalizer = fn _payload, _opts ->
        {:error, {:answer_invalid, {:response, :ambiguous}}}
      end

      assert normalize(valid_payload(), answer_normalizer: answer_normalizer) ==
               {:error, {:revision_invalid, {:answer_invalid, {:response, :ambiguous}}}}
    end

    test "rejects a malformed answer returned by the composition seam" do
      answer_normalizer = fn _payload, _opts -> {:ok, %{action_id: "act_replacement"}} end

      assert normalize(valid_payload(), answer_normalizer: answer_normalizer) ==
               {:error, {:revision_invalid, {:answer, :invalid}}}
    end

    test "rejects answer provenance that differs from trusted context" do
      answer_normalizer = fn _payload, opts ->
        answer = normalized_answer(opts) |> put_in([:actor, :id], "forged-operator")
        {:ok, answer}
      end

      assert normalize(valid_payload(), answer_normalizer: answer_normalizer) ==
               {:error, {:revision_invalid, {:answer, :identity_mismatch}}}
    end

    test "exact retries have the same content hash even when acceptance time changes" do
      assert {:ok, first} = normalize(valid_payload())

      later = DateTime.add(@now, 60, :second)
      assert {:ok, second} = normalize(valid_payload(), now: later)

      assert first.recorded_at != second.recorded_at
      assert first.content_hash == second.content_hash
    end
  end

  describe "follow_up_slug/1" do
    test "derives one bounded attention identity from the revision action" do
      assert {:ok, revision} = normalize(valid_payload())

      slug = DecisionRevision.follow_up_slug(revision)

      assert slug == DecisionRevision.follow_up_slug("act_replacement")
      assert slug != DecisionRevision.follow_up_slug("act_another")
      assert String.length(slug) <= 64
      assert Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, slug)
    end
  end

  describe "follow_up_question/2" do
    test "states non-applicability without claiming prior effects changed" do
      assert {:ok, revision} = normalize(valid_payload())

      question = DecisionRevision.follow_up_question(revision, "985")

      assert question =~ revision.decision_id
      assert question =~ "request version #{revision.decision_version}"
      assert question =~ revision.action_id
      assert question =~ "target ticket 985 is no longer active"
      assert question =~ "could not deliver the new direction automatically"
      assert question =~ "Earlier instructions may already have taken effect"
      refute question =~ ~r/rolled back|reverted|undone/i
      assert String.length(question) <= 2_000
    end
  end

  describe "durable representation" do
    test "round-trips a fully validated revision through the answer codec" do
      assert {:ok, revision} = normalize(valid_payload())

      raw = DecisionRevision.to_json_safe(revision, &encode_answer/1)

      assert {:ok, replayed} = DecisionRevision.from_json_safe(raw, &decode_answer/1)
      assert replayed == revision
    end

    test "rejects tampered revision content even when the shape still decodes" do
      assert {:ok, revision} = normalize(valid_payload())

      raw =
        revision
        |> DecisionRevision.to_json_safe(&encode_answer/1)
        |> Map.put("sequence", 2)

      assert DecisionRevision.from_json_safe(raw, &decode_answer/1) ==
               {:error, :revision_content_hash_mismatch}
    end

    test "rejects a persisted reason that differs from the normalized answer" do
      assert {:ok, revision} = normalize(valid_payload())

      raw =
        revision
        |> DecisionRevision.to_json_safe(&encode_answer/1)
        |> Map.put("reason", "Forged reason")

      assert DecisionRevision.from_json_safe(raw, &decode_answer/1) ==
               {:error, :revision_reason_mismatch}
    end

    test "propagates answer decoder failures" do
      assert {:ok, revision} = normalize(valid_payload())
      raw = DecisionRevision.to_json_safe(revision, &encode_answer/1)

      assert DecisionRevision.from_json_safe(raw, fn _raw -> {:error, :bad_answer} end) ==
               {:error, :bad_answer}
    end
  end

  defp normalize(payload, overrides \\ []) do
    defaults = [
      decision_id: @decision_id,
      decision_version: @decision_version,
      current_action_id: @prior_action_id,
      current_revision_sequence: 0,
      actor: @actor,
      now: @now,
      answer_normalizer: &fake_answer_normalizer/2
    ]

    DecisionRevision.normalize(payload, Keyword.merge(defaults, overrides))
  end

  defp valid_payload do
    %{
      "idempotency_key" => "revision-1",
      "expected_version" => @decision_version,
      "expected_action_id" => @prior_action_id,
      "expected_revision_sequence" => 0,
      "custom_response" => "Use the new direction",
      "rationale" => "Requirements changed"
    }
  end

  defp fake_answer_normalizer(_payload, opts), do: {:ok, normalized_answer(opts)}

  defp normalized_answer(opts, overrides \\ []) do
    content = %{
      action_id: Keyword.get(overrides, :action_id, "act_replacement"),
      decision_id: opts[:decision_id],
      decision_version: opts[:decision_version],
      idempotency_key: "revision-1",
      actor: opts[:actor],
      accepted_at: opts[:now],
      rationale: Keyword.get(overrides, :rationale, "Requirements changed")
    }

    Map.put(content, :content_hash, DecisionValidation.content_hash(Map.delete(content, :accepted_at)))
  end

  defp encode_answer(answer) do
    %{
      "action_id" => answer.action_id,
      "decision_id" => answer.decision_id,
      "decision_version" => answer.decision_version,
      "idempotency_key" => answer.idempotency_key,
      "actor" => %{"kind" => Atom.to_string(answer.actor.kind), "id" => answer.actor.id},
      "accepted_at" => DateTime.to_iso8601(answer.accepted_at),
      "rationale" => answer.rationale,
      "content_hash" => answer.content_hash
    }
  end

  defp decode_answer(raw) do
    with {:ok, accepted_at, _offset} <- DateTime.from_iso8601(raw["accepted_at"]) do
      {:ok,
       %{
         action_id: raw["action_id"],
         decision_id: raw["decision_id"],
         decision_version: raw["decision_version"],
         idempotency_key: raw["idempotency_key"],
         actor: %{kind: String.to_existing_atom(raw["actor"]["kind"]), id: raw["actor"]["id"]},
         accepted_at: accepted_at,
         rationale: raw["rationale"],
         content_hash: raw["content_hash"]
       }}
    end
  end
end
