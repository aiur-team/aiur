defmodule Aiur.BuildOrder.History.Feed do
  @moduledoc "Turns existing daemon observations into raw history facts."
  alias Aiur.BuildOrder.{Lifecycle, History.Row}

  @spec date(term()) :: DateTime.t() | :unknown
  def date(%DateTime{} = value), do: value

  def date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _other -> :unknown
    end
  end

  def date(_value), do: :unknown

  @spec number(term()) :: pos_integer() | nil
  def number(value) when is_integer(value) and value > 0, do: value

  def number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  def number(_value), do: nil

  @spec ref(String.t(), pos_integer()) :: map()
  def ref(repository, n) do
    [owner, repo] = String.split(repository, "/")
    %{owner: owner, repository: repo, number: n}
  end

  @spec event(pos_integer(), map(), DateTime.t(), atom()) :: Row.event()
  def event(n, fields, at, source), do: %{number: n, fields: fields, observed_at: at, source: source}

  @spec issue(Row.t() | nil, map(), DateTime.t(), atom()) :: [Row.event()]
  def issue(held, body, now, source \\ :resource_store) do
    case number(body["number"]) do
      nil ->
        []

      n ->
        lifecycle = Lifecycle.from_github(body["state"], body["state_reason"])
        lifecycle = if lifecycle.state == :closed and lifecycle.state_reason == :none, do: %{lifecycle | state_reason: :unknown}, else: lifecycle
        fields = %{title: body["title"], lifecycle: lifecycle, created_at: date(body["created_at"]), closed_at: if(lifecycle.state == :open, do: :none, else: date(body["closed_at"]))}
        fields = if is_binary(fields.title), do: fields, else: Map.delete(fields, :title)
        fields = Map.merge(fields, label_fields(held, body["labels"], body["updated_at"]))
        [event(n, fields, now, source)]
    end
  end

  @spec labels(Row.t() | nil, pos_integer(), list(), term(), DateTime.t(), atom()) :: [Row.event()]
  def labels(held, n, labels, version, now, source), do: [event(n, label_fields(held, labels, version), now, source)]

  @spec label_fields(Row.t() | nil, term(), term()) :: map()
  def label_fields(held, labels, version) do
    updated = date(version)
    fields = if updated == :unknown, do: %{}, else: %{updated_at: updated}

    label_fields(fields, held, labels, updated)
  end

  defp label_fields(fields, held, labels, updated) when is_list(labels) do
    labels = labels |> Enum.map(&label_name/1) |> Enum.filter(&is_binary/1) |> Enum.map(&String.downcase/1) |> Enum.uniq() |> Enum.sort()
    fields = Map.put(fields, :labels, labels)
    old = if held, do: held.labels, else: :unknown
    label_changes(fields, old, labels, updated)
  end

  defp label_fields(fields, _held, _labels, _updated), do: fields
  defp label_name(label) when is_map(label), do: label["name"]
  defp label_name(label), do: label

  defp label_changes(fields, old, labels, %DateTime{} = updated) when is_list(old) do
    changes = for {action, set} <- [labeled: labels -- old, unlabeled: old -- labels], label <- set, do: %{label: label, action: action, at: updated, actor: :unknown}
    if changes == [], do: fields, else: Map.put(fields, :label_events, changes)
  end

  defp label_changes(fields, _old, _labels, _updated), do: fields

  @spec dependency(Row.t() | nil, map(), String.t(), DateTime.t(), atom()) :: [Row.event()]
  def dependency(%Row{blocked_by: blockers} = held, body, repo, now, source) when is_list(blockers) do
    with n when not is_nil(n) <- number(body["blocked_issue_number"]), b when not is_nil(b) <- number(body["blocking_issue_number"]), present when is_boolean(present) <- body["present"] do
      version = edge_time(body, now)
      blocker = ref(repo, b)
      next = if present, do: Enum.uniq(blockers ++ [blocker]), else: List.delete(blockers, blocker)
      cutoff = full_version(held, :blocked_by_version)
      fields = if cutoff == :unknown, do: %{blocked_by: next}, else: %{blocked_by: next, blocked_by_version: cutoff_string(cutoff)}
      if older_edge?(cutoff, version), do: [], else: [event(n, fields, now, source)]
    else
      _other -> []
    end
  end

  def dependency(_held, _body, _repo, _now, _source), do: []

  @spec sub_issue(Row.t() | nil, map(), String.t(), DateTime.t(), atom()) :: [Row.event()]
  def sub_issue(held, body, repo, now, source) do
    with parent when not is_nil(parent) <- number(body["parent_issue_number"]), sub when not is_nil(sub) <- number(body["sub_issue_number"]) do
      parent_ref = ref(repo, parent)
      version = edge_time(body, now)

      joined_at =
        case date(body["joined_at"]) do
          %DateTime{} = at -> at
          _unknown -> now
        end

      sub_issue_events(body["present"], held, parent_ref, sub, parent, repo, now, joined_at, version, source)
    else
      _other -> []
    end
  end

  defp sub_issue_events(true, held, parent_ref, sub, parent, repo, now, joined_at, version, source) do
    late = held && older_edge?(full_version(held, :parent_version), version)
    child = if late, do: [], else: [event(sub, %{parent: parent_ref, parent_version: DateTime.to_iso8601(version)}, now, source)]
    child ++ [event(parent, %{sub_issues_added: [%{ref: ref(repo, sub), at: joined_at}]}, now, source)]
  end

  defp sub_issue_events(false, held, parent_ref, sub, _parent, _repo, now, _joined_at, version, source) do
    if held && held.parent == parent_ref && not older_edge?(full_version(held, :parent_version), version),
      do: [event(sub, %{parent: :none, parent_version: DateTime.to_iso8601(version)}, now, source)],
      else: []
  end

  defp sub_issue_events(_present, _held, _parent_ref, _sub, _parent, _repo, _now, _joined_at, _version, _source), do: []

  defp cutoff_string(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp cutoff_string(value), do: value

  defp full_version(held, key) do
    case Map.get(held, key) do
      :unknown -> full_snapshot_time(held, key)
      version -> version
    end
  end

  defp full_snapshot_time(held, key) do
    field = if key == :parent_version, do: :parent, else: :blocked_by
    if Map.get(held, field) != :unknown and Enum.any?(held.sources, &(&1 in [:backfill, :catch_up])), do: held.observed_at, else: :unknown
  end

  defp edge_time(body, now) do
    case date(body["edge_version"]) do
      %DateTime{} = version -> version
      _unknown -> now
    end
  end

  defp older_edge?(_held_version, :unknown), do: false

  defp older_edge?(held_version, incoming) do
    case date(held_version) do
      %DateTime{} = held -> DateTime.compare(incoming, held) == :lt
      _unknown -> false
    end
  end

  @spec protect_edges(Row.t() | nil, Row.event()) :: Row.event()
  def protect_edges(nil, event), do: event

  def protect_edges(held, event) do
    fields =
      Enum.reduce([parent: :parent_version, blocked_by: :blocked_by_version], event.fields, fn {key, version_key}, fields ->
        if newer_observation?(held, event, key) or older_edge?(full_version(held, version_key), date(Map.get(fields, version_key))), do: Map.drop(fields, [key, version_key]), else: fields
      end)

    %{event | fields: fields}
  end

  defp newer_observation?(held, event, key), do: Map.get(held, key) != :unknown and DateTime.compare(held.observed_at, event.observed_at) == :gt

  @spec listing(map(), list(), DateTime.t()) :: [Row.event()]
  def listing(rows, issues, listed_from) do
    named = MapSet.new(Enum.map(issues, &number(&1.id)))

    open =
      Enum.flat_map(issues, fn issue ->
        issue(
          Map.get(rows, number(issue.id)),
          %{"number" => issue.id, "title" => issue.title, "state" => "open", "labels" => issue.labels, "created_at" => issue.created_at, "updated_at" => issue.updated_at},
          listed_from,
          :poll
        )
      end)

    closed =
      for {n, %Row{lifecycle: %{state: :open}}} <- rows,
          not MapSet.member?(named, n),
          do: event(n, %{lifecycle: %Lifecycle{state: :closed, state_reason: :unknown}, closed_at: :unknown}, listed_from, :poll)

    open ++ closed
  end

  @spec merge(Row.t() | nil, map(), String.t(), DateTime.t()) :: [Row.event()]
  def merge(held, merge, repo, now) do
    at = date(merge.merged_at)
    n = number(merge.ticket_id)

    if ((String.downcase(merge.repository || "") == repo and not is_nil(n)) && at != :unknown) and
         (is_nil(held) or not is_struct(held.merged_at, DateTime) or DateTime.compare(at, held.merged_at) == :gt) do
      [event(n, %{merged_at: at, pr_number: merge.number}, now, :recent_merge)]
    else
      []
    end
  end
end
