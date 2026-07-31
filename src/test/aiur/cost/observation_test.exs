defmodule Aiur.Cost.ObservationTest do
  use ExUnit.Case, async: true

  alias Aiur.Cost.Observation

  defp codex_message do
    %{
      "params" => %{
        "thread_id" => "thread-1",
        "tokenUsage" => %{
          "total" => %{
            "input_tokens" => 400,
            "output_tokens" => 40,
            "total_tokens" => 440,
            "cached_input_tokens" => 220
          },
          "model_context_window" => 256_000
        }
      }
    }
  end

  test "extracts absolute totals, cached tokens, context window, thread id" do
    assert {:ok, obs} = Observation.from_message("codex", codex_message(), [])
    assert obs.thread_id == "thread-1"
    assert obs.input_tokens == 400
    assert obs.output_tokens == 40
    assert obs.total_tokens == 440
    assert obs.cached_input_tokens == 220
    assert obs.context_window == 256_000
    assert obs.meta.provider == :codex
  end

  test "prefers pricing metadata from the usage envelope" do
    envelope = %Aiur.UsageEnvelope{
      idempotency_key: "k",
      provider: :claude,
      source: :thread_token_usage,
      source_version: "v2",
      source_event_id: "e",
      source_sequence: 1,
      ingested_at: DateTime.utc_now(),
      measurement_kind: :absolute,
      counter_scope: :thread,
      counter_epoch: 0,
      update_kind: :full,
      attribution: %{thread_id: "env-thread"},
      agent_family: :claude,
      backend: :app_server,
      transport: :app_server,
      auth_mode: :api_key,
      account_generation: %{},
      tokens: %{},
      relationship_revision: "claude-remote-control-2026-07",
      resolved_model: "claude-opus-4-8",
      pricing_effective_date: ~D[2026-07-30],
      context_tier: :not_applicable
    }

    assert {:ok, obs} = Observation.from_message("claude", codex_message(), [envelope])
    assert obs.thread_id == "env-thread"
    assert obs.meta.provider == :claude
    assert obs.meta.resolved_model == "claude-opus-4-8"
    assert obs.meta.relationship_revision == "claude-remote-control-2026-07"
    assert obs.meta.pricing_effective_date == ~D[2026-07-30]
  end

  test "resolves thread id + context window through the payload wrapper" do
    # Real codex usage nests params under `payload`.
    message = %{"payload" => codex_message()}
    assert {:ok, obs} = Observation.from_message("codex", message, [])
    assert obs.thread_id == "thread-1"
    assert obs.context_window == 256_000
    assert obs.input_tokens == 400
  end

  test "skips messages without token usage" do
    assert :skip = Observation.from_message("codex", %{"params" => %{"foo" => 1}}, [])
  end
end
