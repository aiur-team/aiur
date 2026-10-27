defmodule Aiur.GitHub.Issues.Normalize do
  @moduledoc false

  alias Aiur.{GitHub, GitHub.IssueExecutorOwner, Issue, TrackerIdentity}
  alias Aiur.GitHub.{Access, BoundedBlockedBy, DependenciesApi, Labels}
  alias Aiur.Orchestrator.DispatchPolicy

  # GitHub's issues collection includes pull requests in the shared number
  # space. Drop them while the raw discriminator is still available so they
  # cannot become zero-label tickets eligible for state-label repair.
  @spec normalize_issue_page([map()], String.t(), String.t(), String.t(), term()) :: [Issue.t()]
  def normalize_issue_page(body, owner, repo, prefix, dispatch_revision) do
    body
    |> Enum.reject(&Map.has_key?(&1, "pull_request"))
    |> Enum.map(&normalize_issue(&1, owner, repo, prefix, dispatch_revision))
  end

  @spec normalize_issue(map(), String.t(), String.t(), String.t()) :: Issue.t()
  def normalize_issue(gh_issue, owner, repo, prefix) when is_map(gh_issue) do
    normalize_issue(gh_issue, owner, repo, prefix, nil)
  end

  @spec normalize_issue(map(), String.t(), String.t(), String.t(), term()) :: Issue.t()
  def normalize_issue(gh_issue, owner, repo, prefix, dispatch_revision) when is_map(gh_issue) do
    number = gh_issue["number"]
    labels = gh_issue["labels"] || []
    label_names = Enum.map(labels, &(&1["name"] || ""))
    state_labels = extract_state_labels(label_names, prefix)

    %Issue{
      id: to_string(number),
      identifier: to_string(number),
      tracker_identity: tracker_identity(gh_issue, owner, repo),
      title: gh_issue["title"],
      description: gh_issue["body"],
      priority: extract_priority(label_names),
      state: extract_state(gh_issue, state_labels),
      state_labels: state_labels,
      branch_name: nil,
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      creator_login: get_in(gh_issue, ["user", "login"]),
      creator_id: get_in(gh_issue, ["user", "id"]),
      creator_type: get_in(gh_issue, ["user", "type"]),
      created_via_app?: created_via_app(gh_issue),
      dispatch_revision: dispatch_revision,
      # `dispatch_authorized?: false` means "not verified to dispatch", and the
      # tri-state `dispatch_authorization` starts `:deferred` ("not yet checked")
      # until `authorize_dispatches` resolves it to `:authorized` or `:denied`
      # from a fetched timeline. `:deferred` must never be read as revoked, so a
      # poll that re-normalizes a running issue without (yet) re-verifying it
      # cannot terminate its agent (#2409).
      dispatch_authorized?: false,
      dispatch_authorization: :deferred,
      paused: paused_label?(label_names, prefix),
      parked: parked_label?(label_names, prefix),
      executor_owner: IssueExecutorOwner.from_labels(label_names, prefix),
      queued: queued_label?(label_names, prefix),
      labels: Enum.map(label_names, &String.downcase/1),
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  @spec hydrate_blocked_by(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def hydrate_blocked_by(%Issue{} = issue) do
    # The dispatch gate must never be served a blocked-by list the store holds
    # that has silently gone stale — a blocker added on GitHub's side without
    # Aiur's own write or a webhook delivery must still hold dispatch, and a
    # blocker that has since closed must stop holding it (#2326). The held
    # body's embedded blocker states cannot be trusted and a conditional read
    # cannot refresh them (#2550, #2552), but re-reading the list on every pass
    # cost two thirds of a daemon's core budget (#2714). So the gate reads the
    # edges and the blocker states separately, each within a stated bound: see
    # `Aiur.GitHub.BoundedBlockedBy`.
    hydrate_blocked_by(issue, revalidate: :bounded)
  end

  @spec hydrate_blocked_by(Issue.t(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def hydrate_blocked_by(%Issue{blocked_by: blockers} = issue, _opts) when blockers != [] do
    {:ok, issue}
  end

  def hydrate_blocked_by(%Issue{id: id} = issue, opts) when is_binary(id) and id != "" do
    case Access.cycle_fetch({:blocked_by, id, opts[:record_max_age_ms]}, fn -> fetch_blocked_by(id, opts) end) do
      {:ok, blockers} when is_list(blockers) ->
        {:ok, %{issue | blocked_by: normalize_blockers(blockers, GitHub.Config.label_prefix())}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected, other}}
    end
  end

  def hydrate_blocked_by(%Issue{} = issue, _opts), do: {:ok, issue}

  defp fetch_blocked_by(id, opts) do
    case Keyword.get(opts, :revalidate) do
      mode when mode in [:bounded, :cached] -> BoundedBlockedBy.fetch(id, opts |> Keyword.delete(:revalidate) |> Keyword.put(:cache_only, mode == :cached))
      _other -> DependenciesApi.fetch_blocked_by(id, opts)
    end
  end

  # Reduces GitHub's native dependency issue objects to the same `blocked_by`
  # shape Linear's normalize_issue produces (`%{id, identifier, state, url}`)
  # so the dispatch gate (`DispatchPolicy.issue_held_by_dependency?`)
  # and the blocker event machinery consume them unchanged. Blocker state comes
  # from the same source as the issue itself: `agent:*` labels, with a raw
  # `state: "closed"` resolving to the terminal "Closed". A blocker with no
  # derivable state keeps `state: nil`, which the gate treats as non-terminal
  # (blocking) — fail-closed on incomplete payloads.
  defp normalize_blockers(blockers, prefix) when is_list(blockers), do: Enum.map(blockers, &normalize_blocker(&1, prefix))

  defp normalize_blocker(blocker, prefix) when is_map(blocker) do
    number = Map.get(blocker, "number")
    labels = Map.get(blocker, "labels") || []
    label_names = Enum.map(labels, &(&1["name"] || ""))

    %{
      id: to_string(number),
      identifier: to_string(number),
      state: extract_state(blocker, label_names, prefix),
      url: Map.get(blocker, "html_url"),
      observed_at_ms: System.system_time(:millisecond)
    }
  end

  defp normalize_blocker(_blocker, _prefix), do: %{id: "", identifier: "", state: nil, url: nil}

  @spec extract_state(map(), [String.t()], String.t()) :: String.t() | nil
  def extract_state(gh_issue, label_names, prefix) do
    gh_issue
    |> extract_state(extract_state_labels(label_names, prefix))
  end

  # A zero-label (`[]`) ticket resolves to `nil` here — the `String | nil`
  # contract for blocker state and expected-state checks — and is told apart
  # from a multi-label ticket by the candidate filter on the `Issue.state_labels`
  # list (`degenerate_state_labels?/1`), not on atoms that never escape this
  # module (#2420). A multi-label (`[_, _ | _]`) ticket is itself resolved
  # deterministically by the clause below (#2384).
  defp extract_state(%{"state" => "closed"}, _state_labels), do: "Closed"
  defp extract_state(_gh_issue, [state]), do: state

  # A ticket carrying two `agent:*` state labels is a broken lifecycle state.
  # `extract_state` used to answer `nil` here, which made every consumer see an
  # "unknown" state — worst of all the CI lifecycle, whose terminal transition
  # would then be skipped and never clear a stale `agent:ci-wait`, stranding the
  # pair as permanently undispatchable (#2366). Resolve the pair deterministically
  # so a state-labeled ticket always has a concrete state.
  defp extract_state(_gh_issue, state_labels) when is_list(state_labels) and state_labels != [],
    do: DispatchPolicy.resolve_state_labels(state_labels)

  defp extract_state(_gh_issue, _state_labels), do: nil

  @spec extract_state_labels([String.t()], String.t()) :: [String.t()]
  def extract_state_labels(label_names, prefix) do
    prefix_colon = normalize_label_name("#{prefix}:")

    label_names
    |> Enum.map(&state_label_suffix(&1, prefix_colon))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec extract_priority([String.t()]) :: integer() | nil
  def extract_priority(label_names), do: Enum.find_value(label_names, &parse_priority_label/1)

  @spec parse_priority_label(String.t()) :: integer() | nil
  def parse_priority_label(name) do
    case Regex.run(~r/^priority:(\d+)$/, name) do
      [_, n] -> parse_priority_int(n)
      _ -> nil
    end
  end

  @spec parse_priority_int(String.t()) :: integer() | nil
  def parse_priority_int(n) do
    case Integer.parse(n) do
      {priority, _} -> priority
      :error -> nil
    end
  end

  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  def parse_datetime(nil), do: nil

  def parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp state_label_suffix(name, prefix_colon) do
    normalized = normalize_label_name(name)

    if String.starts_with?(normalized, prefix_colon) do
      normalized
      |> String.replace_prefix(prefix_colon, "")
      |> state_suffix_unless_preserved()
    end
  end

  defp state_suffix_unless_preserved(suffix),
    do: unless(Labels.marker_suffix?(suffix), do: suffix)

  defp paused_label?(label_names, prefix) when is_list(label_names) do
    paused_label = normalize_label_name("#{prefix}:paused")

    Enum.any?(label_names, fn name ->
      normalize_label_name(name) == paused_label
    end)
  end

  defp parked_label?(label_names, prefix) when is_list(label_names) do
    parked_label = normalize_label_name("#{prefix}:parked")

    Enum.any?(label_names, fn name ->
      normalize_label_name(name) == parked_label
    end)
  end

  defp queued_label?(label_names, prefix) when is_list(label_names) do
    queued_label = normalize_label_name("#{prefix}:queued")

    Enum.any?(label_names, fn name ->
      normalize_label_name(name) == queued_label
    end)
  end

  defp normalize_label_name(label) when is_binary(label),
    do: String.downcase(String.trim(label))

  defp normalize_label_name(_label), do: ""

  # GitHub reports `performed_via_github_app` (null when not App-created) on
  # every issue. An absent key is unknown provenance, which allowed-contributor
  # intake treats as App-created (fail closed).
  defp created_via_app(gh_issue) do
    if Map.has_key?(gh_issue, "performed_via_github_app"),
      do: not is_nil(gh_issue["performed_via_github_app"]),
      else: nil
  end

  defp tracker_identity(gh_issue, owner, repo) do
    case GitHub.Config.configured_repo() do
      {:ok, {configured_owner, configured_repo}} ->
        case TrackerIdentity.from_github(
               gh_issue,
               {configured_owner, configured_repo},
               {owner, repo}
             ) do
          {:ok, identity} ->
            identity

          {:error, reason} ->
            TrackerIdentity.unjoinable(reason,
              owner: configured_owner,
              repository: configured_repo,
              identifier: Map.get(gh_issue, "number")
            )
        end

      {:error, reason} ->
        TrackerIdentity.unjoinable(reason, identifier: Map.get(gh_issue, "number"))
    end
  end
end
