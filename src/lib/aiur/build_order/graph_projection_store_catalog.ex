defmodule Aiur.BuildOrder.GraphProjection.StoreCatalog do
  @moduledoc """
  Builds the Build Order root catalog from `Aiur.GitHub.ResourceStore` content.

  The catalog is one of the four view-state sources #2325 event-sources. Every
  input it needs — the `build-order`-labelled roots, their sub-issue membership,
  and each member's state and labels — already arrives as a webhook delivery and
  is deposited in the store before the event is published, so
  `Aiur.BuildOrder.GraphProjection` rebuilds this catalog from the store
  whenever a store change lands instead of polling GitHub's GraphQL catalog
  query on a cadence.

  ## What is derived and what is not

  A root's own fields (`title`, `url`, `state`, `labels`, timestamps) come from
  its deposited `:issue` body. Its membership metrics — `member_count`, the
  completed/total `progress`, `member_state_digest`, and the `epic`/`phase`
  counts — are derived from the `:sub_issues` edges and each member's held
  `:issue` body, mirroring `Aiur.BuildOrder.GitHubGraph.Normalizer`'s metric
  computation so the event-sourced catalog and the old GraphQL catalog report
  identical numbers for identical state.

  A member whose `:issue` body is missing (its delivery was lost and no degraded
  re-list has re-converged) contributes its state from the `:sub_issues` edge's
  own `sub_issue` object, and its labels count as unresolved — the projection
  fails safe on what it cannot resolve, exactly as the GraphQL reader fails
  closed on an incomplete connection.

  ## Purity

  A plain function, deliberately: `GraphProjection` applies it synchronously
  inside its own GenServer (a store event that lands during a rebuild is applied
  after it), and it unit-tests without booting the store.
  """

  alias Aiur.BuildOrder.{Catalog, Diagnostic, Lifecycle, Metadata, ProviderHealth, RootSummary}
  alias Aiur.GitHub.ResourceStore
  alias Aiur.TrackerIdentity

  @root_label "build-order"

  @doc "Builds the catalog for one `\"owner/repo\"` from the store's held bodies."
  @spec build(String.t() | nil) :: Catalog.t()
  def build(repo_full_name) when is_binary(repo_full_name) do
    {owner, repo} = split_repo(repo_full_name)

    issues = ResourceStore.list_type(:issue, repo_full_name)
    sub_issues = ResourceStore.list_type(:sub_issues, repo_full_name)
    labels = ResourceStore.list_type(:issue_labels, repo_full_name)

    issues_by_node_id = Map.new(issues, fn {_key, body} -> {Map.get(body, "node_id"), body} end)
    issues_by_number = Map.new(issues, fn {_key, body} -> {Map.get(body, "number"), body} end)
    labels_by_number = Map.new(labels, fn {key, body} -> {key_id(key), body} end)

    memberships = memberships_by_parent(sub_issues, issues_by_node_id)

    roots =
      issues
      |> Enum.map(fn {_key, body} -> body end)
      |> Enum.filter(&root?/1)
      |> Enum.map(fn body ->
        root_summary(body, owner, repo, memberships, issues_by_node_id, issues_by_number, labels_by_number)
      end)

    Catalog.new(roots, ProviderHealth.new(1, :healthy, true), [])
  end

  def build(_repo_full_name), do: Catalog.new([], ProviderHealth.new(1, :unavailable, false), [])

  # -- root derivation --------------------------------------------------------

  # A root is an issue carrying the `build-order` label and no `pull_request`
  # key. GitHub serves pull requests from the issues endpoint, and a PR is not a
  # planning root even when it happens to carry the label.
  defp root?(%{"pull_request" => pull_request}) when is_map(pull_request), do: false
  defp root?(body), do: @root_label in label_names(Map.get(body, "labels"))

  defp root_summary(body, owner, repo, memberships, issues_by_node_id, issues_by_number, labels_by_number) do
    {identity, identity_diagnostic} =
      case TrackerIdentity.from_github(body, {owner, repo}, {owner, repo}) do
        {:ok, identity} -> {identity, nil}
        {:error, _reason} -> {nil, Diagnostic.new(:invalid_identity)}
      end

    metrics = member_metrics(memberships, body, issues_by_node_id, issues_by_number, labels_by_number)

    RootSummary.new(%{
      identity: identity,
      title: Map.get(body, "title"),
      icon: nil,
      url: Map.get(body, "html_url"),
      state: Map.get(body, "state"),
      state_reason: Map.get(body, "state_reason") || Map.get(body, "stateReason"),
      labels: label_names(Map.get(body, "labels")),
      created_at: Map.get(body, "created_at"),
      updated_at: Map.get(body, "updated_at"),
      member_count: metrics.member_count,
      epic_count: metrics.epic_count,
      phase_count: metrics.phase_count,
      progress: metrics.progress,
      progress_resolution: metrics.progress_resolution,
      progress_resolved_count: metrics.progress_resolved_count,
      member_state_digest: metrics.member_state_digest
    })
    |> append_diagnostic(identity_diagnostic)
    |> validate_root_label()
  end

  defp append_diagnostic(root, nil), do: root

  defp append_diagnostic(root, diagnostic) do
    %{root | diagnostics: root.diagnostics ++ [diagnostic]}
  end

  defp validate_root_label(%{labels: labels} = root) do
    if @root_label in labels, do: root, else: append_diagnostic(root, Diagnostic.new(:missing_root_label))
  end

  # -- membership -------------------------------------------------------------

  # Groups `:sub_issues` edges by their parent. An edge is keyed by the
  # sub-issue's node id and carries a `parent` object; the parent is matched to
  # a root by number when the delivery carried one, else by node id resolved
  # against the held issue bodies.
  defp memberships_by_parent(sub_issues, issues_by_node_id) do
    Enum.reduce(sub_issues, %{}, fn {_key, edge}, memberships ->
      case parent_of(edge, issues_by_node_id) do
        nil -> memberships
        parent_key -> Map.update(memberships, parent_key, [edge], &[edge | &1])
      end
    end)
  end

  defp parent_of(%{"parent" => parent}, issues_by_node_id) when is_map(parent) do
    case Map.get(parent, "number") do
      number when is_integer(number) ->
        {:number, number}

      _other ->
        case Map.get(parent, "node_id") do
          node_id when is_binary(node_id) ->
            case Map.get(issues_by_node_id, node_id) do
              %{"number" => number} when is_integer(number) -> {:number, number}
              _other -> {:node_id, node_id}
            end

          _other ->
            nil
        end
    end
  end

  defp parent_of(_edge, _issues_by_node_id), do: nil

  defp member_metrics(memberships, body, issues_by_node_id, issues_by_number, labels_by_number) do
    parent_key =
      case Map.get(body, "number") do
        number when is_integer(number) -> {:number, number}
        _other -> {:node_id, Map.get(body, "node_id")}
      end

    members =
      memberships
      |> Map.get(parent_key, [])
      |> Enum.map(&resolve_member(&1, issues_by_node_id, issues_by_number, labels_by_number))

    metrics_from_members(members)
  end

  # The `:sub_issues` edge may not carry every field a metric needs (a delivery
  # can omit `labels`). The member's own `:issue` body is the fuller record, so
  # it wins when held; the edge's `sub_issue` object covers the gap when it is
  # not.
  defp resolve_member(sub_issue, issues_by_node_id, issues_by_number, labels_by_number) do
    held =
      case Map.get(sub_issue, "node_id") do
        node_id when is_binary(node_id) ->
          Map.get(issues_by_node_id, node_id) ||
            Map.get(issues_by_number, Map.get(sub_issue, "number"))

        _other ->
          Map.get(issues_by_number, Map.get(sub_issue, "number"))
      end

    case held do
      %{} = body ->
        %{
          "state" => Map.get(body, "state") || Map.get(sub_issue, "state"),
          "state_reason" => Map.get(body, "state_reason") || Map.get(body, "stateReason"),
          "labels" => held_labels(body, labels_by_number, sub_issue)
        }

      nil ->
        %{
          "state" => Map.get(sub_issue, "state"),
          "state_reason" => Map.get(sub_issue, "state_reason") || Map.get(sub_issue, "stateReason"),
          "labels" => Map.get(sub_issue, "labels")
        }
    end
  end

  defp held_labels(body, labels_by_number, sub_issue) do
    body_labels = Map.get(body, "labels")

    cond do
      is_list(body_labels) and body_labels != [] ->
        body_labels

      is_list(Map.get(labels_by_number, Map.get(body, "number"))) ->
        Map.fetch!(labels_by_number, Map.get(body, "number"))

      is_list(Map.get(sub_issue, "labels")) ->
        Map.fetch!(sub_issue, "labels")

      true ->
        body_labels
    end
  end

  # Mirrors `Aiur.BuildOrder.GitHubGraph.Normalizer.metrics_from_members/2` so
  # the event-sourced catalog and the GraphQL catalog report identical numbers
  # for identical state. A member whose state could not be resolved is left out
  # of the progress denominator (fail-closed, like an unreadable connection),
  # and a member whose labels could not be resolved leaves the epic/phase counts
  # nil rather than asserting a number.
  defp metrics_from_members(members) do
    metadata = Enum.map(members, &member_metadata/1)
    lifecycles = Enum.map(members, &Lifecycle.from_github(Map.get(&1, "state"), Map.get(&1, "state_reason")))
    resolved = Enum.filter(lifecycles, &Lifecycle.valid?/1)
    resolved_count = length(resolved)
    completed_count = Enum.count(resolved, &match?(%Lifecycle{state: :closed, state_reason: :completed}, &1))
    total = length(members)

    {progress, progress_resolution} =
      cond do
        resolved_count == 0 -> {nil, :unresolved}
        resolved_count == total -> {round(completed_count / resolved_count * 100), :resolved}
        true -> {round(completed_count / resolved_count * 100), :partial}
      end

    %{
      member_count: total,
      epic_count: metric_count(metadata, & &1.lane),
      phase_count: metric_count(metadata, & &1.phase),
      progress: progress,
      progress_resolution: progress_resolution,
      progress_resolved_count: resolved_count,
      member_state_digest: member_state_digest(lifecycles)
    }
  end

  defp member_metadata(member) do
    case Map.get(member, "labels") do
      labels when is_list(labels) -> {:ok, Metadata.parse(label_names(labels))}
      _missing -> :unresolved
    end
  end

  defp metric_count(metadata, field) do
    if Enum.all?(metadata, &match?({:ok, _}, &1)) do
      metadata
      |> Enum.map(fn {:ok, member_metadata} -> field.(member_metadata) end)
      |> Enum.uniq()
      |> length()
    else
      nil
    end
  end

  defp member_state_digest(lifecycles) do
    case Enum.filter(lifecycles, &Lifecycle.valid?/1) do
      [] ->
        nil

      resolved ->
        resolved
        |> Enum.map(&{&1.state, &1.state_reason})
        |> Enum.sort()
        |> :erlang.phash2()
    end
  end

  # -- small helpers ----------------------------------------------------------

  defp split_repo(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _other -> {nil, nil}
    end
  end

  # A `:issue_labels` key carries the issue number in the id slot.
  defp key_id({_type, _owner, _repo, id}) do
    case Integer.parse(id) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp label_names(labels) when is_list(labels) do
    labels
    |> Enum.map(&String.downcase(Map.get(&1, "name") || ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp label_names(_labels), do: []
end
