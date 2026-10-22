defmodule Aiur.Config.Schema.VoiceConversationTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.VoiceConversation

  defp parse(conversation), do: Schema.parse(%{"voice" => %{"conversation" => conversation}})

  test "a config without a voice block loads, with no operator decision filled in" do
    assert {:ok, %{voice: %{conversation: conversation}}} = Schema.parse(%{})
    assert conversation.llm == nil
    assert conversation.cloud_disclosure_accepted == nil
  end

  # Phase D, M8: the cap protects the operator's bill, so an omitted key must stay capped.
  test "an omitted daily_minutes_cap loads as the capped default, not nil" do
    assert {:ok, %{voice: %{conversation: %{daily_minutes_cap: 60}}}} = parse(%{})
  end

  test "the operator may change or remove the cap" do
    assert {:ok, %{voice: %{conversation: %{daily_minutes_cap: 15}}}} = parse(%{"daily_minutes_cap" => 15})
    assert {:ok, %{voice: %{conversation: %{daily_minutes_cap: nil}}}} = parse(%{"daily_minutes_cap" => nil})
  end

  # aiur and the core must not disagree about a default; the core is the source of truth.
  test "limit defaults match the core's defaults" do
    {:ok, %{voice: %{conversation: conversation}}} = parse(%{})
    core = VoiceConverse.Config.default_limits()

    for key <- [:max_session_seconds, :idle_timeout_seconds, :daily_minutes_cap, :context_token_budget] do
      assert Map.fetch!(conversation, key) == Map.fetch!(core, key), "#{key} default drifted from the core"
    end
  end

  test "out-of-range values are rejected with the field name" do
    for {key, value} <- [
          {"max_session_seconds", 10},
          {"max_session_seconds", 3_601},
          {"idle_timeout_seconds", 5},
          {"context_token_budget", 64_000},
          {"daily_minutes_cap", -1}
        ] do
      assert {:error, {:invalid_workflow_config, message}} = parse(%{key => value})
      assert message =~ key
    end
  end

  test "a blank llm or agent_id is rejected rather than treated as set" do
    for key <- ["llm", "agent_id"] do
      assert {:error, {:invalid_workflow_config, message}} = parse(%{key => "  "})
      assert message =~ key
    end
  end

  test "roles_dir resolves relative to the config file, an absolute path is kept" do
    assert %{roles_dir: "/tmp/x/.aiur/voice/roles"} =
             VoiceConversation.resolve_roles_dir(%VoiceConversation{roles_dir: "voice/roles"}, "/tmp/x/.aiur/config")

    assert %{roles_dir: "/srv/roles"} =
             VoiceConversation.resolve_roles_dir(%VoiceConversation{roles_dir: "/srv/roles"}, "/tmp/x/.aiur/config")
  end

  # E6-OQ7: the model and the disclosure have no default. The core refuses the session and
  # names the field, which is the same name as the aiur key the operator sets.
  test "settings without llm or disclosure cannot start a session, and the error names the key" do
    {:ok, %{voice: %{conversation: conversation}}} = parse(%{"cloud_disclosure_accepted" => true})
    assert {:error, %{field: :llm, reason: :missing}} = core_session_check(conversation)

    {:ok, %{voice: %{conversation: conversation}}} = parse(%{"llm" => "some-model"})
    assert {:error, %{field: :cloud_disclosure_accepted, reason: :missing}} = core_session_check(conversation)

    {:ok, %{voice: %{conversation: conversation}}} = parse(%{"llm" => "some-model", "cloud_disclosure_accepted" => true})
    assert :ok = core_session_check(conversation)
  end

  defp core_session_check(conversation) do
    {:ok, config} =
      VoiceConverse.Config.new(
        transcript_root: "/tmp/vc",
        credentials: VoiceConverse.Testing.StaticCredentials,
        briefing_source: VoiceConverse.Testing.FakeBriefingSource,
        llm: conversation.llm,
        cloud_disclosure_accepted: conversation.cloud_disclosure_accepted
      )

    VoiceConverse.Config.check_session_start(config)
  end
end
