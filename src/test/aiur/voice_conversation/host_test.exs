defmodule Aiur.VoiceConversation.HostTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema.VoiceConversation, as: Settings
  alias Aiur.VoiceConversation
  alias Aiur.VoiceConversation.BriefingSource

  test "maps resolved settings to a secret-free read-only provider instance" do
    settings = %Settings{
      agent_id: "agent_demo",
      llm: "chosen-model",
      cloud_disclosure_accepted: true,
      max_session_seconds: 90,
      idle_timeout_seconds: 30,
      daily_minutes_cap: nil,
      context_token_budget: 2_000,
      roles_dir: "/tmp/voice-roles"
    }

    assert {:ok, config} = VoiceConversation.build_config(settings, "/tmp/voice-transcripts")
    assert config.name == Aiur.VoiceConversation.Instance
    assert config.provider == {Aiur.VoiceConversation.Provider, [agent_id: "agent_demo"]}
    assert config.credentials == Aiur.VoiceConversation.Credentials
    assert config.agent_channel == nil
    assert config.command_source == nil
    assert config.llm == "chosen-model"
    assert config.roles_dir == "/tmp/voice-roles"
    assert config.transcript_root == "/tmp/voice-transcripts"
    assert config.limits.max_session_seconds == 90
    assert config.limits.idle_timeout_seconds == 30
    assert config.limits.daily_minutes_cap == nil
    assert config.limits.context_token_budget == 2_000
    assert VoiceConverse.availability(config) == :ok

    specs = VoiceConverse.Tools.specs(config, :executor)
    assert Enum.map(specs, & &1.name) == ["get_status", "get_details", "end_conversation"]
    details = Enum.find(specs, &(&1.name == "get_details"))
    assert details.parameters["properties"]["section"]["enum"] == ["transcript", "agents", "decisions"]
  end

  test "an absent Agent id leaves the feature unavailable" do
    assert {:ok, config} = VoiceConversation.build_config(%Settings{}, "/tmp/voice-transcripts")
    assert config.provider == nil
    assert VoiceConverse.availability(config) == {:unavailable, :no_provider}
  end

  test "briefing keeps unavailable data distinct from an explicitly empty run" do
    assert BriefingSource.agents_text(%{}, 10) == "Agent status unavailable."
    assert BriefingSource.agents_text(%{running: []}, 10) == "No running agents."
    assert BriefingSource.transcript_text(%{}, 10) == "Executor transcript unavailable."
    assert BriefingSource.transcript_text(%{events: []}, 10) == "Executor transcript unavailable; no retained conversational turns."
  end

  test "briefing selects bounded running agents, open decisions and conversational turns" do
    assert BriefingSource.agents_text(%{running: [%{identifier: "42", title: "Fix voice", state: "in-progress"}, %{identifier: "43"}]}, 1) ==
             "42: Fix voice; in-progress"

    decisions = [
      %{decision_id: "closed", question: "Old?", decision_status: :resolved},
      %{decision_id: "open", question: "Deploy?", decision_status: :open},
      %{decision_id: "deferred", question: "Later?", decision_status: :deferred}
    ]

    assert BriefingSource.decisions_text(decisions, 1) == "open: Deploy?"

    events = [
      %{role: "user", body: "Old"},
      %{role: "assistant", body: "Latest"},
      %{role: "tool", body: "Private tool output"}
    ]

    assert BriefingSource.transcript_text(%{events: events}, 1) == "assistant: Latest"
  end
end
