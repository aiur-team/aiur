defmodule Aiur.BuildOrder.Published.Document do
  @moduledoc """
  The shared `build-order.v1` envelope and the helpers every document shape
  needs.

  `document/3` fixes the contract marker, the version and the source records so
  the selected-root, catalog and unavailable shapes cannot disagree about the
  envelope. The remaining helpers read one tracker identity or one pack value
  the same way in every shape.
  """

  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.BuildOrder.{Lifecycle, Member}
  alias Aiur.TrackerIdentity

  @contract "aiur.build_order"
  @contract_version 1
  @contract_name "build-order.v1"
  @source_statuses ~w(known stale unknown)

  @spec contract() :: String.t()
  def contract, do: @contract

  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @spec contract_name() :: String.t()
  def contract_name, do: @contract_name

  @spec document(map(), map(), map()) :: map()
  def document(header, sources, records) do
    %{
      "contract" => @contract,
      "contract_version" => @contract_version,
      "build_order_id" => header.build_order_id,
      "title" => header.title,
      "repository" => header.repository,
      "root" => header.root,
      "generated_at" => DateTime.to_iso8601(header.now),
      "sources" => Map.new(sources, fn {key, source} -> {key, normalize_source(source)} end),
      "epics" => records.epics,
      "features" => records.features,
      "lanes" => records.lanes,
      "tickets" => records.tickets,
      "edges" => records.edges,
      "gates" => records.gates,
      "waves" => records.waves,
      "critical_path" => records.critical_path,
      "progress" => records.progress
    }
  end

  defp normalize_source(source) when is_map(source) do
    %{
      "status" => if(source["status"] in @source_statuses, do: source["status"], else: "unknown"),
      "observed_at" => source["observed_at"],
      "reason" => source["reason"]
    }
  end

  @spec progress_opts(boolean(), String.t() | nil, map()) :: keyword()
  def progress_opts(available?, reason, tracker) do
    [
      unavailable?: not available?,
      reason: reason,
      observed_at: tracker["observed_at"]
    ]
  end

  @spec lifecycle_status(term()) :: String.t()
  def lifecycle_status(%Lifecycle{state: :closed, state_reason: :completed}), do: "done"
  def lifecycle_status(%Lifecycle{state: :closed, state_reason: :not_planned}), do: "not_planned"
  def lifecycle_status(%Lifecycle{state: :closed}), do: "closed"
  def lifecycle_status(%Lifecycle{state: :open}), do: "open"
  def lifecycle_status(_lifecycle), do: "unknown"

  @spec repository(term(), term()) :: String.t() | nil
  def repository(%Snapshot{repository: {owner, name}}, _identity)
      when is_binary(owner) and is_binary(name),
      do: owner <> "/" <> name

  def repository(_snapshot, %TrackerIdentity{owner: owner, repository: name})
      when is_binary(owner) and is_binary(name),
      do: owner <> "/" <> name

  def repository(_snapshot, _identity), do: nil

  @spec repository_name(term()) :: String.t() | nil
  def repository_name(%TrackerIdentity{owner: owner, repository: name})
      when is_binary(owner) and is_binary(name),
      do: owner <> "/" <> name

  def repository_name(_identity), do: nil

  @spec identity(term()) :: term()
  def identity(%Snapshot{scope: {:selected, identity}}), do: identity
  def identity(_snapshot), do: nil

  @spec identifier(term()) :: String.t() | nil
  def identifier(%Member{identity: %TrackerIdentity{identifier: identifier}}), do: identifier
  def identifier(%TrackerIdentity{identifier: identifier}), do: identifier
  def identifier(_member), do: nil

  @spec identity_key(term()) :: String.t() | nil
  def identity_key(%TrackerIdentity{} = identity), do: TrackerIdentity.github_key(identity)
  def identity_key(_identity), do: nil

  @spec number_or_nil(term()) :: pos_integer() | nil
  def number_or_nil(identifier) when is_binary(identifier) do
    case Integer.parse(identifier) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  def number_or_nil(_identifier), do: nil

  @spec integer_or_nil(term()) :: integer() | nil
  def integer_or_nil(value) when is_integer(value), do: value

  def integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  def integer_or_nil(_value), do: nil

  @spec string(term()) :: String.t() | nil
  def string(value) when is_binary(value), do: value
  def string(_value), do: nil

  @spec slug(term()) :: String.t() | nil
  def slug(value) when is_binary(value) do
    value
    |> String.split(":")
    |> List.last()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def slug(_value), do: nil

  @spec humanize(String.t()) :: String.t()
  def humanize(key) do
    key
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec prefix_value(term(), String.t()) :: [String.t()]
  def prefix_value(value, prefix) when is_binary(value) do
    if String.starts_with?(value, prefix) do
      case String.trim_leading(value, prefix) do
        "" -> []
        remaining -> [remaining]
      end
    else
      []
    end
  end

  def prefix_value(_value, _prefix), do: []

  @spec sort_key(String.t()) :: tuple()
  def sort_key(id) do
    case Integer.parse(id) do
      {number, ""} -> {0, number, ""}
      _other -> {1, 0, id}
    end
  end
end
