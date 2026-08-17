defmodule Aiur.Linear.Config do
  @moduledoc """
  Linear-specific configuration read from the `linear:` YAML section.
  """

  @behaviour Aiur.TrackerConfig

  alias Aiur.Config.EnvRef

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
    EnvRef.normalize_secret(section_value("api_key"))
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
    EnvRef.normalize_secret(section_value("assignee"))
  end

  @impl Aiur.TrackerConfig
  def validate! do
    cond do
      !is_binary(api_key()) ->
        {:error, "Linear API token missing — set linear.api_key in .aiur/config or LINEAR_API_KEY env var"}

      !is_binary(project_slug()) ->
        {:error, "Linear project slug missing — set linear.project_slug in .aiur/config"}

      true ->
        :ok
    end
  end

  defp section_value(key) do
    Aiur.Config.settings!().tracker.linear
    |> Map.from_struct()
    |> Map.get(String.to_existing_atom(key))
  end
end
