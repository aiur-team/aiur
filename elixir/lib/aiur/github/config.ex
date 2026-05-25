defmodule Aiur.GitHub.Config do
  @moduledoc """
  GitHub-specific configuration read from the `github:` YAML section.
  """

  @behaviour Aiur.TrackerConfig

  @default_label_prefix "aiur"

  @spec repo() :: String.t() | nil
  def repo do
    case section_value("repo") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @spec token() :: String.t() | nil
  def token do
    normalize_secret(System.get_env("GITHUB_TOKEN"))
  end

  @spec label_prefix() :: String.t()
  def label_prefix do
    case section_value("label_prefix") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_label_prefix
          trimmed -> trimmed
        end

      _ ->
        @default_label_prefix
    end
  end

  @doc """
  Returns the GitHub login that Aiur posts under (PR comments, dependency
  declarations, etc.). Read from `github.bot_account` in WORKFLOW.md.
  Returns `nil` when unset — `validate!/0` does not require it, since
  bot identity is only load-bearing for the events foundation (CODEOWNERS
  allowlist self-include + native dependency authorship).
  """
  @spec bot_account() :: String.t() | nil
  def bot_account do
    case section_value("bot_account") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @impl Aiur.TrackerConfig
  def validate! do
    cond do
      !is_binary(token()) ->
        {:error, "GitHub token missing — set GITHUB_TOKEN env var"}

      !is_binary(repo()) ->
        {:error, "GitHub repo missing — set github.repo in WORKFLOW.md"}

      true ->
        :ok
    end
  end

  defp section_value(key) do
    Map.get(Aiur.Config.section("github"), key)
  end

  defp normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret(_value), do: nil
end
