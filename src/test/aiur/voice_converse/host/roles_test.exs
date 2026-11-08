defmodule Aiur.VoiceConverse.Host.RolesTest do
  use ExUnit.Case, async: true
  alias Aiur.VoiceConverse.Host.{Config, Roles}

  test "host supplies both shipped discussion roles and release-embedded glossary" do
    assert {:ok, config} = Config.build(%Aiur.Config.Schema.VoiceConversation{}, "/unused-transcripts")

    assert Enum.map(VoiceConverse.Roles.list(config), &{&1.id, &1.title}) ==
             [{"executor", "Project discussion"}, {"worker", "Ticket discussion"}]

    for id <- ["executor", "worker"] do
      assert {:ok, role} = VoiceConverse.Roles.get(config, id)
      assert role.prompt =~ "Nothing is sent to an agent until"
      assert String.ends_with?(role.prompt, Roles.glossary())
    end
  end

  # Regression guard: embedding at compilation must preserve the single source verbatim.
  test "embedded glossary equals the skill source" do
    assert Roles.glossary() == File.read!(Path.expand("../../../../../.claude/skills/aiur-agent/dictated-input.md", __DIR__))
  end
end
