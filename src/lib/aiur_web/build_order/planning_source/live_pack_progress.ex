defmodule AiurWeb.BuildOrder.PlanningSource.LivePackProgress do
  @moduledoc false

  alias Aiur.BuildOrder.Lifecycle
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator

  @spec current_poll_labels() :: map()
  def current_poll_labels do
    case Orchestrator.dashboard_snapshot() do
      {:current, snapshot, _freshness} ->
        [:running, :retrying, :idle]
        |> Enum.flat_map(&Map.get(snapshot, &1, []))
        |> Enum.reduce(%{}, &put_live_labels/2)

      _unavailable ->
        %{}
    end
  rescue
    _error -> %{}
  catch
    _kind, _reason -> %{}
  end

  @spec load([map()]) :: %{optional({String.t(), String.t()}) => map()}
  def load(packs) do
    packs
    |> Enum.map(& &1.repository)
    |> Enum.uniq()
    |> Map.new(fn {owner, repo} = repository ->
      issues = ResourceStore.list(:issue, owner, repo)
      labels = ResourceStore.list(:issue_labels, owner, repo)
      sub_issues = ResourceStore.list(:sub_issue, owner, repo)
      {repository, %{issues: issues_by_number(issues), labels: labels, members: member_numbers(sub_issues)}}
    end)
  end

  @spec lifecycles(map(), map()) :: %{optional(String.t()) => Lifecycle.t()}
  def lifecycles(%{repository: repository, build_order_id: build_order_id, tickets: tickets}, sources) do
    %{issues: issues, labels: labels, members: members} = Map.get(sources, repository, empty_source())
    ticket_ids = MapSet.new(tickets, & &1.id)

    labels
    |> Enum.flat_map(&matching_order_number(&1, issues, build_order_id))
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

  defp issues_by_number(issues) do
    Enum.reduce(issues, %{}, fn {_key, entry}, acc ->
      case Map.get(entry, :data) do
        %{"number" => number} = issue when not is_nil(number) -> Map.put(acc, number, issue)
        _bodyless -> acc
      end
    end)
  end

  defp member_numbers(entries) do
    Enum.reduce(entries, %{}, fn {_key, entry}, acc ->
      case Map.get(entry, :data) do
        %{"present" => true, "parent_issue_number" => parent, "sub_issue_number" => sub}
        when is_integer(parent) and is_integer(sub) ->
          Map.update(acc, parent, [sub], &[sub | &1])

        _other ->
          acc
      end
    end)
  end

  defp empty_source, do: %{issues: %{}, labels: [], members: %{}}

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

  defp put_live_labels(row, labels_by_identity) do
    case {Map.get(row, :tracker_identity), Map.get(row, :labels)} do
      {%Aiur.TrackerIdentity{} = identity, [_ | _] = labels} ->
        Map.put(labels_by_identity, Aiur.TrackerIdentity.github_key(identity), labels)

      _row ->
        labels_by_identity
    end
  end
end
