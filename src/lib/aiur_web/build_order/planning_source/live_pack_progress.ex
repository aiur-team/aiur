defmodule AiurWeb.BuildOrder.PlanningSource.LivePackProgress do
  @moduledoc false

  alias Aiur.BuildOrder.{CatalogStore, Lifecycle}
  alias Aiur.GitHub.ResourceStore

  @spec lifecycles(map()) :: %{optional(String.t()) => Lifecycle.t()}
  def lifecycles(%{repository: {owner, repo}, build_order_id: build_order_id, tickets: tickets}) do
    issues =
      ResourceStore.list(:issue, owner, repo)
      |> Enum.reduce(%{}, fn {_key, entry}, acc ->
        case Map.get(entry, :data) do
          %{"number" => number} = issue when is_integer(number) -> Map.put(acc, number, issue)
          _other -> acc
        end
      end)

    root_numbers =
      ResourceStore.list(:issue_labels, owner, repo)
      |> Enum.flat_map(&matching_order_number(&1, issues, build_order_id))

    members = CatalogStore.member_numbers({owner, repo})
    ticket_ids = MapSet.new(tickets, & &1.id)

    root_numbers
    |> Enum.flat_map(&Map.get(members, &1, []))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn number, acc ->
      case issue_member(Map.get(issues, number), build_order_id, ticket_ids) do
        {ticket_id, %Lifecycle{} = lifecycle} -> Map.put(acc, ticket_id, lifecycle)
        nil -> acc
      end
    end)
  end

  defp matching_order_number({{:issue_labels, _owner, _repo, id}, entry}, issues, build_order_id) do
    number = parse_issue_number(id)
    labels = issue_label_names(Map.get(entry, :data))

    if is_integer(number) and "build-order" in labels and order_id?(Map.get(issues, number), build_order_id),
      do: [number],
      else: []
  end

  defp matching_order_number(_entry, _issues, _build_order_id), do: []

  defp order_id?(%{"body" => body}, build_order_id) when is_binary(body),
    do: String.contains?(body, "Build Order id: `#{build_order_id}`")

  defp order_id?(_issue, _build_order_id), do: false

  defp issue_member(%{"body" => body} = issue, build_order_id, ticket_ids) when is_binary(body) do
    with [_, suffix] <- String.split(body, "Build Order member: `", parts: 2),
         [ticket_id, metadata] <- String.split(suffix, "`", parts: 2),
         true <- MapSet.member?(ticket_ids, ticket_id),
         true <- String.starts_with?(metadata, " (#{build_order_id}, "),
         lifecycle <- Lifecycle.from_github(Map.get(issue, "state"), Map.get(issue, "state_reason")),
         true <- Lifecycle.valid?(lifecycle) do
      {ticket_id, lifecycle}
    else
      _unmatched -> nil
    end
  end

  defp issue_member(_issue, _build_order_id, _ticket_ids), do: nil

  defp parse_issue_number(value) when is_integer(value) and value > 0, do: value

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _invalid -> nil
    end
  end

  defp parse_issue_number(_value), do: nil

  defp issue_label_names(labels) when is_list(labels), do: Enum.map(labels, &Map.get(&1, "name"))
  defp issue_label_names(_labels), do: []
end
