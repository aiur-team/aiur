defmodule Aiur.RunTelemetry.FeatureEpics do
  @moduledoc false
  alias Aiur.GitHub.{ResourceEvents, ResourceStore}
  alias Aiur.RunTelemetry.EpicMembers

  @spec subscribe(String.t()) :: :ok
  def subscribe(repo) do
    :ok = ResourceEvents.subscribe(:issue_labels, repo)
    ResourceEvents.subscribe(:sub_issue, repo)
  end

  @spec discover(String.t(), String.t(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def discover(repo, label, opts) do
    suffix = "/issues?" <> URI.encode_query(%{"labels" => label, "state" => "all", "per_page" => 100})

    with {:ok, rows} <- EpicMembers.get(repo, suffix, opts) do
      if length(rows) >= 100, do: {:error, :epic_discovery_limit}, else: {:ok, for(row <- rows, is_nil(row["pull_request"]), do: row["number"])}
    end
  end

  @spec labels(String.t(), String.t(), integer()) :: %{String.t() => boolean()}
  def labels(repo, label, discovered_at) do
    [owner, name] = String.split(repo, "/")

    ResourceStore.list(:issue_labels, owner, name)
    |> Enum.filter(fn {_key, entry} -> (entry.fetched_at_ms || 0) > discovered_at * 1_000 end)
    |> Map.new(fn {{_type, _owner, _name, id}, entry} -> {to_string(id), Enum.any?(entry.data || [], &(label_name(&1) == label))} end)
  end

  defp label_name(%{"name" => name}), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(_invalid), do: nil
end
