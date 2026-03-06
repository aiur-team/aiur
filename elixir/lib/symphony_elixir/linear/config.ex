defmodule SymphonyElixir.Linear.Config do
  @moduledoc """
  Linear-specific configuration read from the `linear:` YAML section.
  """

  @behaviour SymphonyElixir.TrackerConfig

  @default_endpoint "https://api.linear.app/graphql"

  @spec endpoint() :: String.t()
  def endpoint do
    case section_value("endpoint") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_endpoint
    end
  end

  @spec api_key() :: String.t() | nil
  def api_key do
    section_value("api_key")
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret()
  end

  @spec project_slug() :: String.t() | nil
  def project_slug do
    case section_value("project_slug") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @spec assignee() :: String.t() | nil
  def assignee do
    section_value("assignee")
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret()
  end

  @impl SymphonyElixir.TrackerConfig
  def validate! do
    cond do
      !is_binary(api_key()) ->
        {:error, "Linear API token missing — set linear.api_key in WORKFLOW.md or LINEAR_API_KEY env var"}

      !is_binary(project_slug()) ->
        {:error, "Linear project slug missing — set linear.project_slug in WORKFLOW.md"}

      true ->
        :ok
    end
  end

  defp section_value(key) do
    Map.get(SymphonyElixir.Config.section("linear"), key)
  end

  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp normalize_secret(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret(_value), do: nil
end
