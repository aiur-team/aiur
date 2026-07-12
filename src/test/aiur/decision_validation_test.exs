defmodule Aiur.DecisionValidationTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionValidation

  @ticket %{identifier: "979", title: "OCC-1", url: "https://github.com/its-everdred/aiur/issues/979"}
  @source %{agent_id: "agent-1", session_id: "session-1", event_id: nil}

  defp normalize(payload, opts \\ []) do
    DecisionValidation.normalize(payload, Keyword.merge([ticket: @ticket, source: @source], opts))
  end

  describe "happy path" do
    test "a minimal valid payload normalizes with safe defaults" do
      assert {:ok, decision} = normalize(%{"question" => "Deploy now?", "blocking" => true})

      assert decision.question == "Deploy now?"
      assert decision.blocking == true
      assert decision.authority == :human_required
      assert decision.urgency == :normal
      assert decision.reversibility == :irreversible
      assert decision.version == 1
      assert decision.schema_version == 1
      assert decision.options == []
      assert decision.recommendation == nil
      assert decision.artifacts == []
      assert decision.ticket.identifier == "979"
      assert decision.source.agent_id == "agent-1"
      assert is_binary(decision.content_hash)
      assert String.starts_with?(decision.decision_id, "dec_")
    end

    test "a full payload with options and a matching recommendation normalizes" do
      payload = %{
        "question" => "Which approach?",
        "blocking" => true,
        "authority" => "supervisor_allowed",
        "urgency" => "high",
        "reversibility" => "reversible",
        "kind" => "architecture",
        "context" => %{
          "short_summary" => "Two viable approaches.",
          "long_context_markdown" => "# Details\n\nMore context here."
        },
        "options" => [
          %{"id" => "a", "label" => "Option A", "description" => "desc", "risk" => "low"},
          %{"id" => "b", "label" => "Option B"}
        ],
        "recommendation" => %{"option_id" => "a", "reason" => "simpler"},
        "consequence_of_delay" => "Work stalls.",
        "source_id" => "retry-key-1"
      }

      assert {:ok, decision} = normalize(payload)
      assert decision.authority == :supervisor_allowed
      assert decision.urgency == :high
      assert decision.reversibility == :reversible
      assert decision.kind == "architecture"
      assert decision.context.short_summary == "Two viable approaches."
      assert length(decision.options) == 2
      assert decision.recommendation == %{option_id: "a", reason: "simpler"}
      assert decision.source_id == "retry-key-1"
    end

    test "option ids may repeat a source id without collision across tickets" do
      payload = %{"question" => "Q?", "blocking" => false, "source_id" => "same-key"}

      {:ok, a} = normalize(payload, ticket: %{identifier: "111"})
      {:ok, b} = normalize(payload, ticket: %{identifier: "222"})

      refute a.decision_id == b.decision_id
    end

    test "the same ticket and source id produce the same canonical decision_id (replay dedup identity)" do
      payload = %{"question" => "Q?", "blocking" => false, "source_id" => "retry-1"}

      {:ok, first} = normalize(payload)
      {:ok, second} = normalize(payload)

      assert first.decision_id == second.decision_id
    end

    test "omitting source_id mints a non-replayable decision_id each time" do
      payload = %{"question" => "Q?", "blocking" => false}

      {:ok, first} = normalize(payload)
      {:ok, second} = normalize(payload)

      refute first.decision_id == second.decision_id
    end

    test "trusted legacy-attention provenance is normalized and integrity protected" do
      legacy_attention = %{
        slug: "scope-question",
        topic: "ticket.979.agent.attention.scope-question"
      }

      payload = %{
        "question" => "Which scope should own this?",
        "blocking" => true,
        "source_id" => "legacy_attention:scope-question"
      }

      assert {:ok, decision} = normalize(payload, legacy_attention: legacy_attention)
      assert decision.legacy_attention == legacy_attention

      assert {:ok, without_provenance} = normalize(payload)
      refute decision.content_hash == without_provenance.content_hash
    end

    test "legacy-attention provenance must match its trusted ticket and slug" do
      payload = %{
        "question" => "Which scope should own this?",
        "blocking" => true,
        "source_id" => "legacy_attention:scope-question"
      }

      assert normalize(payload,
               legacy_attention: %{
                 slug: "scope-question",
                 topic: "ticket.111.agent.attention.scope-question"
               }
             ) ==
               {:error, {:decision_invalid, {:legacy_attention_topic, :mismatch}}}

      assert normalize(payload,
               legacy_attention: %{
                 slug: "bad\nslug",
                 topic: "ticket.979.agent.attention.bad\nslug"
               }
             ) ==
               {:error, {:decision_invalid, {:legacy_attention_slug, :invalid_format}}}
    end
  end

  describe "trusted context injection" do
    test "ticket and source come only from opts, never the payload" do
      payload = %{
        "question" => "Q?",
        "blocking" => true,
        "ticket" => %{"identifier" => "attacker-ticket"},
        "source" => %{"agent_id" => "attacker-agent"}
      }

      assert {:ok, decision} = normalize(payload)
      assert decision.ticket.identifier == "979"
      assert decision.source.agent_id == "agent-1"
    end

    test "a forged source-reported timestamp never becomes canonical created_at" do
      fixed_now = ~U[2026-01-01 00:00:00Z]
      payload = %{"question" => "Q?", "blocking" => true, "created_at" => "1999-01-01T00:00:00Z"}

      assert {:ok, decision} = normalize(payload, now: fixed_now)
      assert decision.created_at == fixed_now
      assert decision.source_created_at == ~U[1999-01-01 00:00:00Z]
    end

    test "externally controlled ticket title and URL are bounded and redacted" do
      secret = "GHSAT0" <> String.duplicate("A", 36)

      ticket = %{
        identifier: "979",
        title: "Leaked #{secret}",
        url: "https://github.com/its-everdred/aiur/issues/979?token=#{secret}"
      }

      assert {:ok, decision} = normalize(%{"question" => "Q?", "blocking" => true}, ticket: ticket)
      refute decision.ticket.title =~ secret
      refute decision.ticket.url =~ secret
      assert decision.ticket.title =~ "[REDACTED:ghsat]"
      assert decision.ticket.url =~ "[REDACTED:ghsat]"

      overlong_ticket = %{ticket | title: String.duplicate("x", 501)}

      assert normalize(%{"question" => "Q?", "blocking" => true}, ticket: overlong_ticket) ==
               {:error, {:decision_invalid, {:ticket_title, :too_long}}}
    end
  end

  describe "required fields" do
    test "missing question fails" do
      assert normalize(%{"blocking" => true}) == {:error, {:decision_invalid, {:question, :missing}}}
    end

    test "missing blocking fails" do
      assert normalize(%{"question" => "Q?"}) == {:error, {:decision_invalid, {:blocking, :missing}}}
    end

    test "a non-boolean blocking fails" do
      assert normalize(%{"question" => "Q?", "blocking" => "yes"}) ==
               {:error, {:decision_invalid, {:blocking, :invalid_type}}}
    end

    test "an empty question fails" do
      assert normalize(%{"question" => "  ", "blocking" => true}) ==
               {:error, {:decision_invalid, {:question, :too_short}}}
    end

    test "an overlong question fails" do
      assert normalize(%{"question" => String.duplicate("a", 2001), "blocking" => true}) ==
               {:error, {:decision_invalid, {:question, :too_long}}}
    end

    test "unsafe control characters in the question fail" do
      question = "bad " <> <<0>> <> " byte"

      assert normalize(%{"question" => question, "blocking" => true}) ==
               {:error, {:decision_invalid, {:question, :unsafe_characters}}}
    end

    test "newlines and tabs in the question are allowed" do
      assert {:ok, decision} = normalize(%{"question" => "line one\nline two\ttabbed", "blocking" => true})
      assert decision.question =~ "\n"
    end
  end

  describe "artifact bounds" do
    test "rejects an oversized artifact reference before canonicalization" do
      oversized_url = "https://github.com/" <> String.duplicate("a", 4_097)

      assert normalize(%{
               "question" => "Inspect it?",
               "blocking" => true,
               "artifacts" => [oversized_url]
             }) ==
               {:error, {:decision_invalid, {:artifacts, :too_long}}}
    end
  end

  describe "enums" do
    test "an invalid authority value fails" do
      assert normalize(%{"question" => "Q?", "blocking" => true, "authority" => "nonsense"}) ==
               {:error, {:decision_invalid, {:authority, :invalid_enum}}}
    end

    test "an invalid urgency value fails" do
      assert normalize(%{"question" => "Q?", "blocking" => true, "urgency" => "nonsense"}) ==
               {:error, {:decision_invalid, {:urgency, :invalid_enum}}}
    end

    test "an invalid reversibility value fails" do
      assert normalize(%{"question" => "Q?", "blocking" => true, "reversibility" => "nonsense"}) ==
               {:error, {:decision_invalid, {:reversibility, :invalid_enum}}}
    end

    test "a never-before-seen enum string is rejected instead of crashing" do
      novel = "totally_novel_atom_value_#{System.unique_integer([:positive])}"

      assert normalize(%{"question" => "Q?", "blocking" => true, "authority" => novel}) ==
               {:error, {:decision_invalid, {:authority, :invalid_enum}}}
    end
  end

  describe "options" do
    test "duplicate option ids fail" do
      payload = %{
        "question" => "Q?",
        "blocking" => true,
        "options" => [%{"id" => "a", "label" => "A"}, %{"id" => "a", "label" => "A2"}]
      }

      assert normalize(payload) == {:error, {:decision_invalid, {:options, :duplicate_id}}}
    end

    test "too many options fail" do
      options = for i <- 1..21, do: %{"id" => "opt-#{i}", "label" => "Option #{i}"}
      payload = %{"question" => "Q?", "blocking" => true, "options" => options}

      assert normalize(payload) == {:error, {:decision_invalid, {:options, :too_many}}}
    end

    test "an option missing a label fails" do
      payload = %{"question" => "Q?", "blocking" => true, "options" => [%{"id" => "a"}]}
      assert normalize(payload) == {:error, {:decision_invalid, {:option_label, :missing}}}
    end

    test "a custom-response-only request needs no invented options" do
      assert {:ok, decision} = normalize(%{"question" => "Q?", "blocking" => true})
      assert decision.options == []
    end
  end

  describe "recommendation" do
    test "a recommendation pointing at a real option passes" do
      payload = %{
        "question" => "Q?",
        "blocking" => true,
        "options" => [%{"id" => "a", "label" => "A"}],
        "recommendation" => %{"option_id" => "a"}
      }

      assert {:ok, decision} = normalize(payload)
      assert decision.recommendation.option_id == "a"
    end

    test "a dangling recommendation fails" do
      payload = %{
        "question" => "Q?",
        "blocking" => true,
        "options" => [%{"id" => "a", "label" => "A"}],
        "recommendation" => %{"option_id" => "missing"}
      }

      assert normalize(payload) == {:error, {:decision_invalid, {:recommendation, :dangling_option_id}}}
    end
  end

  describe "security" do
    test "known secret patterns are redacted before hashing/persistence" do
      secret = "ghp_" <> String.duplicate("a", 36)
      payload = %{"question" => "Leak? #{secret}", "blocking" => true}

      assert {:ok, decision} = normalize(payload)
      refute decision.question =~ secret
      assert decision.question =~ "[REDACTED:ghp]"
    end

    test "redaction runs in nested option text too" do
      secret = "sk-" <> String.duplicate("a", 20)

      payload = %{
        "question" => "Q?",
        "blocking" => true,
        "options" => [%{"id" => "a", "label" => "A", "description" => secret}]
      }

      assert {:ok, decision} = normalize(payload)
      [option] = decision.options
      refute option.description =~ secret
      assert option.description =~ "[REDACTED:sk]"
    end

    test "a relative artifact path is rejected" do
      payload = %{"question" => "Q?", "blocking" => true, "artifacts" => ["relative/path.md"]}

      assert normalize(payload) ==
               {:error, {:decision_invalid, {:artifacts, :artifact_path_not_absolute}}}
    end

    test "a non-allowlisted artifact URL host is rejected" do
      payload = %{"question" => "Q?", "blocking" => true, "artifacts" => ["https://evil.example/x"]}

      assert normalize(payload) ==
               {:error, {:decision_invalid, {:artifacts, :artifact_url_host_not_allowed}}}
    end

    test "an allowlisted artifact URL passes" do
      payload = %{"question" => "Q?", "blocking" => true, "artifacts" => ["https://github.com/its-everdred/aiur"]}
      assert {:ok, decision} = normalize(payload)
      assert [%{kind: :url}] = decision.artifacts
    end

    test "the persisted %{kind:, value:} artifact shape (not just a raw string) is accepted on replay" do
      # Aiur.DecisionProjection.to_json_safe/1 persists artifacts as
      # %{"kind" =>, "value" =>} maps, and replay feeds that shape straight
      # back into normalize/2 — it must not require the raw-string ingress
      # shape only, or every persisted Decision with an artifact would fail
      # replay validation and be flagged as corrupt.
      payload = %{
        "question" => "Q?",
        "blocking" => true,
        "artifacts" => [%{"kind" => "url", "value" => "https://github.com/its-everdred/aiur"}]
      }

      assert {:ok, decision} = normalize(payload)
      assert [%{kind: :url, value: "https://github.com/its-everdred/aiur"}] = decision.artifacts
    end
  end

  describe "content_hash/1" do
    test "equivalent content produces the same hash regardless of key order" do
      a = %{question: "Q?", blocking: true, kind: nil}
      b = %{kind: nil, blocking: true, question: "Q?"}

      assert DecisionValidation.content_hash(a) == DecisionValidation.content_hash(b)
    end

    test "different content produces a different hash" do
      a = %{question: "Q1?", blocking: true}
      b = %{question: "Q2?", blocking: true}

      refute DecisionValidation.content_hash(a) == DecisionValidation.content_hash(b)
    end
  end
end
