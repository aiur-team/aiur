defmodule Aiur.BuildOrder.Catalog do
  @moduledoc """
  A bounded root catalog that never lets one invalid entry hide its siblings.

  It also owns the rule for carrying label-derived counts across the cheaper
  catalog polls that cannot resolve them — see `carry_forward_counts/2`.
  """

  alias Aiur.{BuildOrder.Diagnostic, BuildOrder.ProviderHealth, BuildOrder.RootSummary, TrackerIdentity}

  @max_entries 100

  @type count_resolution_failure :: :budget | :timeout | :upstream | nil

  @type selection ::
          {:ok, RootSummary.t()}
          | {:structurally_invalid, RootSummary.t()}
          | {:provider_stale, RootSummary.t()}
          | {:provider_unavailable, RootSummary.t()}
          | :not_found
  @type t :: %__MODULE__{
          entries: [RootSummary.t()],
          provider: ProviderHealth.t(),
          diagnostics: [Diagnostic.t()],
          search_paths: [Path.t()],
          count_resolution_failure: count_resolution_failure()
        }

  defstruct entries: [], provider: %ProviderHealth{}, diagnostics: [], search_paths: [], count_resolution_failure: nil

  @spec new(term(), term(), keyword()) :: t()
  def new(entries, provider, opts \\ [])

  def new(entries, provider, opts) when is_list(entries) and is_list(opts) do
    overflow? = length(entries) > @max_entries
    entries = Enum.take(entries, @max_entries)

    diagnostics =
      overflow_diagnostic(overflow?) ++ invalid_root_diagnostic(entries)

    %__MODULE__{
      entries: Enum.map(entries, &root_summary/1),
      provider: provider_health(provider),
      diagnostics: diagnostics,
      search_paths: search_paths(opts)
    }
  end

  def new(_entries, provider, opts) when is_list(opts),
    do: %__MODULE__{
      provider: provider_health(provider),
      diagnostics: [Diagnostic.new(:catalog_overflow)],
      search_paths: search_paths(opts)
    }

  @doc "Attaches the bounded reason epic and wave counts could not be resolved."
  @spec put_count_resolution_failure(t(), count_resolution_failure()) :: t()
  def put_count_resolution_failure(%__MODULE__{} = catalog, failure)
      when failure in [:budget, :timeout, :upstream, nil],
      do: %{catalog | count_resolution_failure: failure}

  # Most catalog polls deliberately skip the per-member `labels` connection
  # (#1766), so they cannot resolve `epic_count`/`phase_count` and report nil.
  # Without this, the two columns would flap to "Unresolved" between the slow
  # labelled reads.
  #
  # The fingerprint is deliberately conservative but it is *not* proof that the
  # counts are still right, and this comment will not claim that it is. Both
  # counts are derived from the members' `build-lane:`/`phase:` labels, and
  # GitHub does not bump a parent issue's `updatedAt` when a sub-issue is
  # relabelled. So a member moving from `phase:1` to `phase:2` — the most common
  # way one of these counts goes stale — matches the fingerprint exactly and is
  # carried. What the fingerprint does rule out is the coarser drift: a root
  # replaced by another, a member added or removed, or the root itself edited.
  # The residual staleness window is one labelled-read cadence, and the caller
  # bounds it further by refusing to carry once that cadence stops succeeding.
  #
  # Everything else fails closed: a differing member count or timestamp, an
  # unreadable identity, or a missing timestamp all leave the count nil so the
  # column honestly reads "Unresolved" instead of showing a number from a root
  # we cannot match. A freshly resolved count always wins; this only fills a nil.
  @spec carry_forward_counts(t(), term()) :: t()
  def carry_forward_counts(%__MODULE__{} = fresh, %__MODULE__{} = previous) do
    resolved = resolved_counts_by_key(previous.entries)

    if resolved == %{} do
      fresh
    else
      %{fresh | entries: Enum.map(fresh.entries, &carry_entry(&1, resolved))}
    end
  end

  def carry_forward_counts(%__MODULE__{} = fresh, _previous), do: fresh

  defp resolved_counts_by_key(entries) do
    for %RootSummary{} = entry <- entries,
        key = carry_key(entry),
        not is_nil(key),
        is_integer(entry.epic_count) or is_integer(entry.phase_count),
        into: %{},
        do: {key, {entry.epic_count, entry.phase_count}}
  end

  defp carry_entry(%RootSummary{epic_count: epics, phase_count: phases} = entry, _resolved)
       when is_integer(epics) and is_integer(phases),
       do: entry

  defp carry_entry(%RootSummary{} = entry, resolved) do
    case Map.get(resolved, carry_key(entry)) do
      {epic_count, phase_count} ->
        %{entry | epic_count: fill(entry.epic_count, epic_count), phase_count: fill(entry.phase_count, phase_count)}

      nil ->
        entry
    end
  end

  defp carry_entry(entry, _resolved), do: entry

  # The key *is* the fingerprint: an entry only matches a previous entry when
  # its identity, member count, and update timestamp all agree, so a lookup hit
  # means the root itself and the size of its membership did not move. See the
  # note on `carry_forward_counts/2` for what that does and does not establish.
  defp carry_key(%RootSummary{identity: %TrackerIdentity{} = identity, member_count: members, updated_at: %DateTime{} = updated_at})
       when is_integer(members) do
    case TrackerIdentity.github_key(identity) do
      {:github, _owner, _repository, _id} = key -> {key, members, DateTime.to_unix(updated_at, :microsecond)}
      _key -> nil
    end
  end

  defp carry_key(_entry), do: nil

  defp fill(nil, carried) when is_integer(carried) and carried >= 0, do: carried
  defp fill(current, _carried), do: current

  @doc """
  The change marker the catalog holds for one root, or `nil`.

  Deliberately **not** `carry_key/1`, because the two answer different questions
  and conflating them broke one of them. `carry_key/1` asks "may I reuse the
  epic/phase counts I resolved last time?", which stays true while the members'
  *labels* are unchanged — a member closing does not invalidate it. This asks
  "must I re-read this root's graph?", which a member closing very much does.

  So this adds the members' lifecycle digest to the triple. That matters more
  than it sounds: **GitHub does not bump a parent issue's `updatedAt` when a
  sub-issue closes**, and closing does not change `member_count` either, so
  without the digest the single most important change a Build Order page can show
  — a member finishing — left this marker byte-identical and the graph was never
  re-read. The digest costs nothing: the catalog query already asks every member
  for `state`/`stateReason`.

  What it still does not catch is a member being *relabelled*: the catalog read
  that produces this marker deliberately omits the per-member `labels` connection
  because that variant costs 26 points against 1 (#1766). That gap belongs to the
  plan's slow safety sweep.

  `nil` means "no comparable marker", which is deliberately different from a
  marker that differs. A caller must not read the difference between two `nil`s
  as evidence of anything.
  """
  @spec root_fingerprint(t(), term()) :: term() | nil
  def root_fingerprint(%__MODULE__{entries: entries}, identity) do
    case Enum.find(entries, &same_identity?(&1.identity, identity)) do
      %RootSummary{} = root -> change_key(root)
      _other -> nil
    end
  end

  def root_fingerprint(_catalog, _identity), do: nil

  defp change_key(%RootSummary{member_state_digest: digest} = root) do
    case carry_key(root) do
      nil -> nil
      key -> {key, digest}
    end
  end

  @spec select(t(), term()) :: selection()
  def select(%__MODULE__{} = catalog, identity) do
    case Enum.find(catalog.entries, &same_identity?(&1.identity, identity)) do
      nil -> :not_found
      root -> selection(root, catalog.provider)
    end
  end

  defp selection(root, provider) do
    if RootSummary.valid?(root),
      do: provider_selection(root, provider),
      else: {:structurally_invalid, root}
  end

  defp provider_selection(root, provider) do
    if ProviderHealth.usable?(provider), do: {:ok, root}, else: unavailable_selection(root, provider)
  end

  defp unavailable_selection(root, %ProviderHealth{state: :stale}), do: {:provider_stale, root}
  defp unavailable_selection(root, _provider), do: {:provider_unavailable, root}
  defp provider_health(%ProviderHealth{} = provider), do: provider
  defp provider_health(_provider), do: %ProviderHealth{}
  defp root_summary(%RootSummary{} = root), do: root
  defp root_summary(_root), do: RootSummary.new(%{})

  defp overflow_diagnostic(true), do: [Diagnostic.new(:catalog_overflow)]
  defp overflow_diagnostic(false), do: []

  defp search_paths(opts) do
    opts
    |> Keyword.get(:search_paths, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp invalid_root_diagnostic(entries) do
    if Enum.all?(entries, &match?(%RootSummary{}, &1)), do: [], else: [Diagnostic.new(:invalid_root)]
  end

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    case {TrackerIdentity.github_key(left), TrackerIdentity.github_key(right)} do
      {{:github, _, _, _} = left_key, {:github, _, _, _} = right_key} -> left_key == right_key
      _ -> false
    end
  end

  defp same_identity?(_left, _right), do: false
end
