defmodule Aiur.DecisionProvenanceTest do
  use ExUnit.Case, async: true

  alias Aiur.DecisionProvenance

  @captured_at ~U[2026-07-13 12:00:00Z]

  test "captures the bounded trusted runtime facts with a nested schema version" do
    runtime = %{
      agent_family: "codex",
      backend: "codex",
      requested_model: "gpt-5.6-terra",
      resolved_model: "gpt-5.6-terra",
      session_id: "thread-123",
      attempt_id: "attempt-456",
      source: "agent_runner"
    }

    assert {:ok, provenance} = DecisionProvenance.normalize(runtime, @captured_at)
    assert provenance.schema_version == 1
    assert provenance.agent_family == "codex"
    assert provenance.backend == "codex"
    assert provenance.requested_model == "gpt-5.6-terra"
    assert provenance.resolved_model == "gpt-5.6-terra"
    assert provenance.session_id == "thread-123"
    assert provenance.attempt_id == "attempt-456"
    assert provenance.source == "agent_runner"
    assert provenance.captured_at == @captured_at

    assert {:ok, decoded} = provenance |> DecisionProvenance.to_json_safe() |> DecisionProvenance.from_json_safe()
    assert decoded == provenance
  end

  test "keeps unavailable model facts unknown" do
    assert {:ok, provenance} =
             DecisionProvenance.normalize(
               %{backend: "claude", session_id: "thread-123", source: "agent_runner"},
               @captured_at
             )

    assert provenance.requested_model == nil
    assert provenance.resolved_model == nil
  end

  test "restamps trusted struct provenance at acceptance" do
    assert {:ok, previous} =
             DecisionProvenance.normalize(
               %{backend: "codex", session_id: "thread-123", source: "agent_runner"},
               @captured_at
             )

    accepted_at = DateTime.add(@captured_at, 60, :second)

    assert {:ok, accepted} = DecisionProvenance.normalize(previous, accepted_at)
    assert accepted.captured_at == accepted_at
    assert accepted.backend == previous.backend
    assert accepted.session_id == previous.session_id
  end

  test "rejects raw session, account, and capability material" do
    assert {:error, {:provenance, {:unknown_fields, ["raw_session"]}}} =
             DecisionProvenance.normalize(
               %{backend: "codex", source: "agent_runner", raw_session: %{"prompt" => "secret"}},
               @captured_at
             )

    assert {:error, {:provenance, {:backend, :invalid_format}}} =
             DecisionProvenance.normalize(
               %{backend: "account@example.com", source: "agent_runner"},
               @captured_at
             )

    assert {:error, {:provenance, {:session_id, :invalid_format}}} =
             DecisionProvenance.normalize(
               %{session_id: "https://capability.example/token", source: "agent_runner"},
               @captured_at
             )
  end

  test "rejects account, organization, prompt, transcript, and credential fields" do
    for field <- ["account", "email", "organization", "prompt", "transcript", "credential"] do
      assert {:error, {:provenance, {:unknown_fields, [^field]}}} =
               DecisionProvenance.normalize(
                 Map.put(%{backend: "codex", source: "agent_runner"}, field, "sensitive"),
                 @captured_at
               )
    end
  end

  test "rejects credential-shaped values in every allowed runtime identity field" do
    credential = "ghp_123456789012345678901234567890123456"
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0aHJlYWQiLCJpYXQiOjF9.signature"

    for field <- [:agent_family, :backend, :requested_model, :resolved_model, :session_id, :attempt_id] do
      assert {:error, {:provenance, {^field, :redacted_secret}}} =
               DecisionProvenance.normalize(Map.put(%{source: "agent_runner"}, field, credential), @captured_at)

      assert {:error, {:provenance, {^field, :redacted_secret}}} =
               DecisionProvenance.normalize(Map.put(%{source: "agent_runner"}, field, jwt), @captured_at)
    end
  end
end
