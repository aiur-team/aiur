defmodule Aiur.VoiceConverse.Host.Roles do
  @moduledoc "Release-safe default discussion roles and the dictated-input glossary."

  @glossary_path Path.expand("../../../../../.claude/skills/aiur-agent/dictated-input.md", __DIR__)
  @external_resource @glossary_path
  @glossary File.read!(@glossary_path)

  @spec glossary() :: String.t()
  def glossary, do: @glossary

  @spec defaults() :: [map()]
  def defaults do
    dir = Application.app_dir(:aiur, "priv/voice_roles")
    VoiceConverse.Roles.load(%VoiceConverse.Config{roles_dir: dir}).roles
  end
end
