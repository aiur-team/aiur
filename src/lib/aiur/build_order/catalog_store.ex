defmodule Aiur.BuildOrder.CatalogStore do
  @moduledoc """
  Builds the Build Order catalog from `Aiur.GitHub.ResourceStore` instead of a
  GraphQL fetch.

  This is the event-sourced half of the catalog's source of truth (#2313). The
  store already receives every input the catalog query asks GitHub for — issue
  lifecycle and labels via the `issues` delivery and `Aiur.GitHub.WriteThrough`,
  membership edges via `sub_issues` deliveries, dependency edges via
  `issue_dependencies` deliveries — so a projection that reads the store renders
  the catalog without spending a single GraphQL point. The GraphQL
  `build_order_catalog` read survives only as the rare reconciliation (daemon
  boot, degraded delivery mode) that re-converges the store after a dropped
  delivery.

  The metric rules here deliberately mirror `Aiur.BuildOrder.GitHubGraph.Normalizer`
  (progress, lane/phase counts, member-state digest), so a store-projected root
  and a GitHub-read root make the same claims from the same member facts. The
  bodies differ — the store holds GitHub's REST shape while the normalizer reads
  GraphQL nodes — so the derivation is written out rather than shared.
  """

  alias Aiur.BuildOrder.{Catalog, Diagnostic, Lifecycle, Metadata, ProviderHealth, ProviderResult, RootSummary}
  alias Aiur.GitHub.{Config, ResourceStore}
  alias Aiur.TrackerIdentity

  @root_label "build-order"
  @member_limit 100

  @type repository :: {String.t(), String.t()}

  @spec fetch(keyword()) :: Aiur.BuildOrder.GitHubGraph.result()
  def fetch(opts \\ []) do
    case repository(opts) do
      {:ok, repository} ->
        catalog = build_catalog(repository)

        {:ok,
         ProviderResult.complete(catalog,
           calls: 0,
           pages: 0,
           diagnostics: catalog.diagnostics
         )}

      {:error, reason} ->
        {:error, ProviderResult.failed(reason, calls: 0, pages: 0)}
    end
  end

  # -- catalog assembly -----------------------------------------------------

  defp build_catalog(repository) do
    issues = issues_by_number(repository)
    labels = labels_by_number(repository)
    memberships = memberships_by_parent(repository)

    roots =
      labels
      |> Enum.filter(fn {_number, issue_labels} -> @root_label in issue_labels end)
      |> Enum.map(fn {number, _labels} -> number end)
      |> Enum.sort()
      |> Enum.map(fn number ->
        root_summary(
          Map.get(issues, number),
          Map.get(labels, number, []),
          Map.get(memberships, number, []),
          issues,
          labels,
          repository
        )
      end)

    Catalog.new(roots, healthy_provider())
  end

  defp root_summary(nil, root_labels, member_numbers, _issues, _labels, _repository) do
    # The store knows a root exists (its label set was delivered) but has no
    # body for it yet — the reconciliation will fill it. Reported with its
    # labels and member edge count rather than dropped, so the page can still
    # move towards convergence.
    RootSummary.new(%{
      labels: root_labels,
      member_count: length(member_numbers)
    })
  end

  defp root_summary(issue, root_labels, member_numbers, issues, labels, repository) do
    {identity, identity_diagnostic} = identity(issue, repository)
    {parent, parent_diagnostic} = parent_identity(issue, repository)
    metrics = root_metrics(member_numbers, issues, labels)

    RootSummary.new(%{
      identity: identity,
      title: Map.get(issue, "title"),
      url: Map.get(issue, "html_url") || Map.get(issue, "url"),
      parent_identity: parent,
      state: Map.get(issue, "state"),
      state_reason: Map.get(issue, "state_reason"),
      labels: root_labels,
      created_at: datetime(Map.get(issue, "created_at")),
      updated_at: datetime(Map.get(issue, "updated_at")),
      member_count: metrics.member_count,
      epic_count: metrics.epic_count,
      phase_count: metrics.phase_count,
      progress: metrics.progress,
      progress_resolution: metrics.progress_resolution,
      progress_resolved_count: metrics.progress_resolved_count,
      member_state_digest: metrics.member_state_digest
    })
    |> append_diagnostics([identity_diagnostic, parent_diagnostic])
    |> validate_root_label()
  end

  defp validate_root_label(%RootSummary{labels: labels} = root) do
    if @root_label in labels, do: root, else: append_diagnostics(root, [Diagnostic.new(:missing_root_label)])
  end

  # -- metrics, mirroring GitHubGraph.Normalizer ----------------------------

  # Progress comes from `state`/`stateReason`; lane and phase counts come from
  # each member's labels. A member whose body or labels the store does not hold
  # yet is unresolved: the member still counts (the edge exists), but it cannot
  # contribute a lifecycle or a lane, so the metrics degrade exactly the way the
  # GitHub path degrades on an unreadable connection.
  defp root_metrics(member_numbers, issues, labels) do
    members = Enum.take(member_numbers, @member_limit)
    lifecycles = Enum.map(members, &member_lifecycle(&1, issues))
    metadata = Enum.map(members, &member_metadata(&1, labels))
    total = length(members)
    resolved = Enum.filter(lifecycles, &Lifecycle.valid?/1)
    resolved_count = length(resolved)
    completed_count = Enum.count(resolved, &match?(%Lifecycle{state: :closed, state_reason: :completed}, &1))

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

  defp member_lifecycle(number, issues) do
    case Map.get(issues, number) do
      %{} = issue -> Lifecycle.from_github(Map.get(issue, "state"), Map.get(issue, "state_reason"))
      _missing -> %Lifecycle{state: :unknown, state_reason: :none}
    end
  end

  defp member_metadata(number, labels) do
    case Map.get(labels, number) do
      nil -> :unresolved
      issue_labels -> {:ok, Metadata.parse(issue_labels)}
    end
  end

  # Distinct-value count over a metadata dimension, matching
  # `GitHubGraph.Normalizer.metric_count/2` exactly. `Metadata.parse/1` never
  # yields nil: a member carrying no `build-lane:`/`phase:` label lands on
  # `:unassigned`/`:unphased`, and that placeholder counts as one distinct group.
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

  # The same change signal `GitHubGraph.Normalizer.member_state_digest/1`
  # computes: a hash of the members' valid lifecycles, `nil` when none resolve.
  defp member_state_digest([]), do: nil

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

  # -- store readers --------------------------------------------------------

  defp issues_by_number(repository) do
    repository
    |> store_entries(:issue)
    |> Enum.reduce(%{}, fn {_key, entry}, acc ->
      case issue_number(entry) do
        nil -> acc
        number -> Map.put(acc, number, entry.data)
      end
    end)
  end

  defp labels_by_number(repository) do
    repository
    |> store_entries(:issue_labels)
    |> Enum.reduce(%{}, fn {{_type, _owner, _repo, id}, entry}, acc ->
      case positive_number(id) do
        nil -> acc
        number -> Map.put(acc, number, label_names(entry.data))
      end
    end)
  end

  # parent issue number => sorted member issue numbers, from the `present` edges
  # only. A tombstoned edge (a `*_removed` that arrived later than a stale add)
  # contributes nothing.
  defp memberships_by_parent(repository), do: member_numbers(repository)

  @doc """
  Maps each parent issue number to its member issue numbers, from the store's
  `present` `:sub_issue` edges.

  Public for `Aiur.BuildOrder.GraphProjection`, which uses it to decide which
  watched roots a dependency-edge change touches. Returns `%{}` when no store
  is running.
  """
  @spec member_numbers(repository()) :: %{pos_integer() => [pos_integer()]}
  def member_numbers(repository) do
    repository
    |> store_entries(:sub_issue)
    |> Enum.reduce(%{}, fn {_key, entry}, acc ->
      case Map.get(entry, :data) do
        %{"present" => true, "parent_issue_number" => parent, "sub_issue_number" => sub}
        when is_integer(parent) and is_integer(sub) ->
          Map.update(acc, parent, [sub], &[sub | &1])

        _other ->
          acc
      end
    end)
    |> Map.new(fn {parent, subs} -> {parent, Enum.sort(subs)} end)
  end

  defp store_entries({owner, repository}, type), do: ResourceStore.list(type, owner, repository)

  defp issue_number(%{data: %{"number" => number}}) when is_integer(number) and number > 0, do: number

  defp issue_number(%{data: %{"number" => number}}) when is_binary(number), do: positive_number(number)

  defp issue_number(_entry), do: nil

  defp label_names(nil), do: []
  defp label_names(labels) when is_list(labels), do: labels |> Enum.map(&Map.get(&1, "name")) |> Enum.reject(&is_nil/1)
  defp label_names(_labels), do: []

  # -- identity -------------------------------------------------------------

  defp identity(issue, repository) do
    case TrackerIdentity.from_github(issue, repository, repository) do
      {:ok, identity} -> {identity, nil}
      {:error, _reason} -> {nil, Diagnostic.new(:invalid_identity)}
    end
  end

  defp parent_identity(%{"parent" => %{} = parent}, repository) do
    case TrackerIdentity.from_github(parent, repository, repository) do
      {:ok, identity} -> {identity, nil}
      {:error, _reason} -> {nil, Diagnostic.new(:invalid_identity)}
    end
  end

  defp parent_identity(_issue, _repository), do: {nil, nil}

  defp repository(opts) do
    case Keyword.get(opts, :repository) do
      {owner, repo} = repository when is_binary(owner) and is_binary(repo) ->
        {:ok, repository}

      _unset ->
        case Config.configured_repo() do
          {:ok, repository} -> {:ok, repository}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp healthy_provider, do: ProviderHealth.new(1, :healthy, true)

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp datetime(_value), do: nil

  defp positive_number(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp append_diagnostics(%RootSummary{diagnostics: diagnostics} = record, additions) do
    %{record | diagnostics: diagnostics ++ Enum.reject(additions, &is_nil/1)}
  end
end
