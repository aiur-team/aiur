defmodule SymphonyElixir.GitHub.Config do
  @moduledoc """
  GitHub-specific configuration read from the `github:` YAML section.
  """

  @behaviour SymphonyElixir.TrackerConfig

  @default_label_prefix "symphony"

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

  @impl SymphonyElixir.TrackerConfig
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
    Map.get(SymphonyElixir.Config.section("github"), key)
  end

  defp normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret(_value), do: nil
end
