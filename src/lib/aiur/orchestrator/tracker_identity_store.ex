defmodule Aiur.Orchestrator.TrackerIdentityStore do
  @moduledoc false

  alias Aiur.{Executor.StatePaths, JsonStore, TrackerIdentity}

  @spec load() :: %{optional(String.t()) => TrackerIdentity.t()}
  def load do
    case JsonStore.read(path(), %{}) do
      {:ok, persisted} when is_map(persisted) ->
        Map.new(persisted, fn {identifier, encoded} -> {identifier, restore(encoded)} end)
        |> Enum.reject(fn {_identifier, identity} -> is_nil(identity) end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @spec save(%{optional(String.t()) => TrackerIdentity.t()}) :: :ok
  def save(identities) when is_map(identities) do
    identities
    |> Enum.filter(fn {identifier, identity} ->
      TrackerIdentity.joinable?(identity) and to_string(identifier) == identity.identifier
    end)
    |> Map.new(fn {identifier, identity} -> {identifier, Jason.encode!(identity)} end)
    |> then(&JsonStore.write!(path(), &1))
  end

  defp restore(encoded) when is_binary(encoded) do
    with {:ok, %{"kind" => "github", "owner" => owner, "repository" => repository, "provider_id" => provider_id, "identifier" => identifier} = fields} <- Jason.decode(encoded),
         {:ok, identity} <- TrackerIdentity.from_github(%{"node_id" => provider_id, "number" => identifier, "database_id" => fields["database_id"]}, {owner, repository}, {owner, repository}) do
      identity
    else
      _ -> nil
    end
  end

  defp restore(_encoded), do: nil

  defp path do
    Application.get_env(:aiur, :tracker_identity_store_path) || StatePaths.tracker_identities_path()
  end
end
