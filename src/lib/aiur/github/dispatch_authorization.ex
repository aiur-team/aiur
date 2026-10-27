defmodule Aiur.GitHub.DispatchAuthorization do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{Access, Config, LocalProvenance, MainFixer, StatePolicy, TimelineCache}
  alias Aiur.GitHub.DispatchAuthorization.Timeline
  alias Aiur.{Issue, Signal}

  @cache_key {__MODULE__, :timeline_cache}
  # The timeline cache holds full event lists — up to four pages of 100 raw
  # events per issue. `:persistent_term.put/2` triggers a global literal-area GC
  # across every process, so holding those lists there (and rewriting them on
  # every dispatch attempt) is exactly the failure this table avoids: ETS is
  # reference-counted and GC-agnostic. Only the small fingerprint/decision/alert
  # caches stay in `:persistent_term` (#2298 rework B4).
  @max_cache_entries 1_000
  @deferral_alert_threshold 5

  @spec authorize(Issue.t(), String.t(), String.t(), String.t(), keyword()) :: Issue.t()
  def authorize(issue, owner, repo, prefix, opts \\ [])

  def authorize(%Issue{state_labels: [_, _ | _] = state_labels} = issue, _owner, _repo, _prefix, _opts) do
    deny_ambiguous(issue, {:contradictory_state_labels, state_labels})
  end

  # Verified label provenance is primary; App fixers and registered local provenance are narrow exceptions.
  #
  # Creator allowlisting alone previously let agents enqueue their own work.
  #
  # Who *filed* a ticket says nothing about whether anyone decided it should
  # run. Requiring the verified label applier costs one timeline fetch per
  # issue — verified decisions are cached per `{id, label, updated_at}` — and makes "an actor
  # in `allowed_users` moved this into a dispatch state" the single, auditable
  # precondition; agent-authored markers never confer authority.
  def authorize(%Issue{} = issue, owner, repo, prefix, opts) do
    authorize_label_applier(issue, owner, repo, prefix, allowed_users(opts), opts)
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)

    TimelineCache.clear()

    :ok
  end

  defp authorize_label_applier(issue, owner, repo, prefix, allowed_users, opts) do
    case trigger_label(issue, prefix) do
      {:ok, label} ->
        issue
        |> label_applier_decision(label, prefix, owner, repo, opts)
        |> apply_label_decision(issue, allowed_users, opts)

      :error ->
        deny_ambiguous(issue, :missing_trigger_label)
    end
  end

  defp trigger_label(%Issue{state: state}, prefix) when is_binary(state) and state != "",
    do: {:ok, StatePolicy.state_label(prefix, state)}

  defp trigger_label(_issue, _prefix), do: :error

  defp label_applier_decision(issue, label, prefix, owner, repo, opts) do
    cached_decision(issue, label) || fetch_decision(issue, label, prefix, owner, repo, opts)
  end

  # The trigger label is the issue's CURRENT state label, and Aiur moves that
  # label itself on every transition (`agent:todo` → `agent:in-progress` → …)
  # using the bot credential. So the latest applier of the current state label
  # is routinely Aiur, not the human who triaged the ticket.
  #
  # Requiring the applier to be in `allowed_users` and stopping there would mean
  # every ticket loses authorization the moment Aiur advances its state, and
  # `Orchestrator.Reconciler` terminates the running agent with "dispatch
  # authorization was revoked" on the next poll. The old `trusted_creator`
  # short-circuit hid that for operator-filed tickets; removing it exposed it
  # for all of them.
  #
  # So: an Aiur-applied state label carries forward the triage decision instead
  # of replacing it — authorized only if some allowed user applied a
  # `<prefix>:*` label to this issue at some point. That keeps the invariant
  # that a human put this ticket into the pipeline, while letting Aiur drive its
  # own state machine. Note this deliberately does NOT extend to any other
  # actor: an outsider re-labelling a ticket still revokes, because "latest
  # applier wins" is what stops a hostile relabel from riding a stale approval.
  defp apply_label_decision({:verified, actor, event_id, prefix_appliers, label_actors}, issue, allowed_users, opts) do
    triaged_by = Enum.find(prefix_appliers, &member?(allowed_users, &1))

    {authorized?, source} =
      cond do
        MainFixer.authorized?(issue, opts) and aiur_actor?(actor, opts) -> {true, "main_watch_fixer"}
        member?(allowed_users, actor) -> {true, "label_applier"}
        aiur_actor?(actor, opts) and not is_nil(triaged_by) -> {true, "prior_triage:#{triaged_by}"}
        true -> LocalProvenance.decision(issue, actor, label_actors, opts)
      end

    log_decision(
      if(authorized?, do: :allow, else: :deny),
      issue,
      source,
      actor,
      event_id
    )

    authorization = if authorized?, do: :authorized, else: :denied
    clear_deferrals(issue)
    %{issue | dispatch_authorized?: authorized?, dispatch_authorization: authorization}
  end

  defp apply_label_decision({:ambiguous, reason}, issue, _allowed_users, _opts), do: deny_ambiguous(issue, reason)

  # A resource/transport failure on the provenance fetch is NOT a provenance
  # verdict. `{:deferred, reason}` means "could not check right now" — a budget
  # hold, rate limit, or transport outage — so the issue is not dispatched this
  # cycle (fail-closed) but is deliberately not marked revoked: a running agent
  # must not be killed, and once the cause clears the next poll re-verifies
  # from a fresh timeline and the ticket returns to dispatchable with no
  # operator action (#2409).
  defp apply_label_decision({:deferred, reason}, issue, _allowed_users, _opts) do
    cause = deferral_cause(reason)

    Logger.warning(
      "GitHub dispatch authorization deferred issue_id=#{inspect(issue.id)} " <>
        "issue_identifier=#{inspect(issue.identifier)} cause=#{cause} reason=#{inspect(reason)} " <>
        "state=#{inspect(issue.state)}; ticket is not dispatched this cycle and no " <>
        "running agent is revoked (transient, not a provenance denial)"
    )

    maybe_alert_deferral(issue, cause, reason)
    note_deferral(issue, cause, reason)

    %{issue | dispatch_authorized?: false, dispatch_authorization: :deferred}
  end

  # A denial that comes from OUR OWN read limits reads identically to a denial
  # that comes from provenance unless it is labelled: both just stop dispatching.
  # khala#257 cost an hour of investigation for exactly that reason. `cause=` is
  # the grep handle, and `transport_limit` is the one cause an operator can do
  # nothing about from GitHub's side, so it also gets a durable alert (#2797).
  defp deferral_cause({:timeline_truncated, _per_page}), do: "transport_limit"
  defp deferral_cause(:timeline_page_limit_exceeded), do: "transport_limit"
  defp deferral_cause(_reason), do: "transient"

  defp maybe_alert_deferral(issue, "transport_limit", reason),
    do: maybe_alert_once(issue, {:transport_limit, reason}, &alert_transport_limit/2)

  defp maybe_alert_deferral(_issue, _cause, _reason), do: :ok

  # Aiur's own identity, never a human decision. Both logins count, and it has
  # to be both: the state label above is written with the *daemon's* credential,
  # so under GitHub App auth the actor on the timeline event is the App bot —
  # while an agent moving a label with its own credential appears as the bot
  # account. Matching only one of them makes the other's transition read as a
  # third party relabelling the ticket, which denies authorization and gets the
  # running agent killed on the next reconcile. When neither is configured
  # nothing carries forward and the stricter latest-applier rule applies
  # unchanged.
  defp aiur_actor?(actor, opts) do
    trimmed = actor |> String.trim() |> String.downcase()

    trimmed != "" and trimmed in aiur_logins(opts)
  end

  defp aiur_logins(opts) do
    [
      Keyword.get_lazy(opts, :bot_account, &Config.bot_account/0),
      Keyword.get_lazy(opts, :daemon_account, &Config.daemon_account/0)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp fetch_decision(issue, label, prefix, owner, repo, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Access.default_request_fun/1)
    token = Keyword.get(opts, :token, Config.token())

    if is_binary(token) and token != "" do
      case Timeline.fetch(request_fun, token, owner, repo, issue, opts) do
        {:ok, events, new_etag, single_page?, per_page} ->
          TimelineCache.put(owner, repo, issue.id, new_etag, events, single_page?, per_page)
          decide_fetched_timeline(issue, label, prefix, events, owner, repo)

        {:reused, events} ->
          decide_fetched_timeline(issue, label, prefix, events, owner, repo)

        # The timeline could not be fetched or parsed — a budget hold, rate
        # limit, transport failure, or pagination/truncation limit. None of
        # these is a provenance finding: the fetch produced no label evidence
        # either way, so this is a *deferred* authorization (not dispatched this
        # cycle, never treated as revoked) rather than an `:ambiguous` denial.
        # A genuinely hostile relabel still revokes — that verdict comes from
        # `timeline_decision` over a fetched timeline, which this branch never
        # reaches (#2409).
        {:error, reason} ->
          {:deferred, reason}
      end
    else
      {:ambiguous, :missing_github_token}
    end
  end

  defp decide_fetched_timeline(issue, label, prefix, events, owner, repo) do
    decision = Timeline.decision(issue, label, prefix, events)

    case decision do
      {:verified, _actor, event_id, _prefix_appliers, _label_actors} ->
        cache_decision(issue, label, event_id, decision)

      _other ->
        :ok
    end

    # GitHub may expose an issue created with its label before the corresponding
    # timeline event is indexed. An incomplete read cannot be kept by either the
    # decision cache or the transport read cache: updated_at need not move when
    # that event appears, and a webhook-backed read can otherwise stay stale for
    # an hour. Retire only this issue's cached reads so the next poll asks again.
    if match?({:ambiguous, _reason}, decision) or match?({:deferred, _reason}, decision) do
      invalidate_incomplete_timeline(issue.id, owner, repo)
    end

    decision
  end

  defp invalidate_incomplete_timeline(id, owner, repo) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 ->
        Access.invalidate([{:number, String.downcase(owner), String.downcase(repo), number}])

      _other ->
        :ok
    end
  end

  defp invalidate_incomplete_timeline(_id, _owner, _repo), do: :ok

  defp cached_decision(%Issue{id: id, updated_at: updated_at}, label) when is_binary(id) do
    cache = cache()
    fingerprint = {id, label, updated_at}

    with event_id when is_binary(event_id) <- Map.get(cache.fingerprints, fingerprint),
         decision when not is_nil(decision) <- Map.get(cache.decisions, {id, label, event_id}) do
      decision
    end
  end

  defp cached_decision(_issue, _label), do: nil

  defp cache_decision(
         %Issue{id: id, updated_at: updated_at},
         label,
         event_id,
         decision
       )
       when is_binary(id) do
    cache = cache()
    fingerprint = {id, label, updated_at}

    updated = %{
      fingerprints: Map.put(cache.fingerprints, fingerprint, event_id),
      decisions: Map.put(cache.decisions, {id, label, event_id}, decision),
      alerted: cache.alerted,
      deferrals: cache.deferrals
    }

    :persistent_term.put(
      @cache_key,
      if(map_size(updated.decisions) > @max_cache_entries,
        do: %{fingerprints: %{}, decisions: %{}, alerted: %{}, deferrals: cache.deferrals},
        else: updated
      )
    )
  end

  defp cache_decision(_issue, _label, _event_id, _decision), do: :ok

  defp allowed_users(opts) do
    opts
    |> Keyword.get(:allowed_users, Config.allowed_users())
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp member?(allowed_users, login),
    do: MapSet.member?(allowed_users, String.downcase(String.trim(login)))

  defp log_decision(decision, issue, source, actor, event_id, reason \\ nil) do
    Logger.info(
      "GitHub dispatch authorization decision=#{decision} issue_id=#{inspect(issue.id)} " <>
        "issue_identifier=#{inspect(issue.identifier)} " <>
        "creator=#{inspect(issue.creator_login)} source=#{source} actor=#{inspect(actor)} " <>
        "label_event_id=#{inspect(event_id)} reason=#{inspect(reason)}"
    )
  end

  defp deny_ambiguous(issue, reason) do
    log_decision(:deny, issue, "ambiguous", nil, nil, reason)
    maybe_alert_ambiguity(issue, reason)
    clear_deferrals(issue)
    %{issue | dispatch_authorized?: false, dispatch_authorization: :denied}
  end

  defp maybe_alert_ambiguity(issue, reason), do: maybe_alert_once(issue, reason, &alert_ambiguity/2)

  defp maybe_alert_once(%Issue{id: id, updated_at: updated_at} = issue, reason, emit)
       when is_binary(id) do
    alert_key = {id, updated_at, reason}
    cache = cache()

    unless Map.has_key?(cache.alerted, alert_key) do
      alerted =
        cache.alerted
        |> bounded_alert_cache()
        |> Map.put(alert_key, true)

      :persistent_term.put(@cache_key, %{cache | alerted: alerted})
      emit.(issue, reason)
    end
  end

  defp maybe_alert_once(issue, reason, emit), do: emit.(issue, reason)

  defp cache do
    :persistent_term.get(@cache_key, %{fingerprints: %{}, decisions: %{}, alerted: %{}, deferrals: %{}})
  end

  defp note_deferral(%Issue{id: id} = issue, cause, reason) when is_binary(id) do
    cache = cache()
    existing = Map.get(cache.deferrals, id, %{count: 0, alerted?: false})
    count = existing.count + 1
    should_alert? = cause != "transport_limit" and count >= @deferral_alert_threshold and not existing.alerted?
    deferral = %{count: count, alerted?: existing.alerted? or should_alert?}
    deferrals = cache.deferrals |> bounded_deferral_cache() |> Map.put(id, deferral)
    :persistent_term.put(@cache_key, %{cache | deferrals: deferrals})
    if should_alert?, do: alert_persistent_deferral(issue, reason)
  end

  defp note_deferral(_issue, _cause, _reason), do: :ok

  defp clear_deferrals(%Issue{id: id} = issue) when is_binary(id) do
    cache = cache()

    case Map.pop(cache.deferrals, id) do
      {nil, _deferrals} ->
        :ok

      {%{alerted?: true}, deferrals} ->
        :persistent_term.put(@cache_key, %{cache | deferrals: deferrals})
        alert_deferral_resolved(issue)

      {_streak, deferrals} ->
        :persistent_term.put(@cache_key, %{cache | deferrals: deferrals})
    end
  end

  defp clear_deferrals(_issue), do: :ok

  defp bounded_deferral_cache(deferrals) when map_size(deferrals) >= @max_cache_entries, do: %{}
  defp bounded_deferral_cache(deferrals), do: deferrals

  defp alert_persistent_deferral(issue, reason) do
    Signal.agent_alert(
      deferral_topic(issue.id),
      "Dispatch remains deferred for issue #{issue.identifier || issue.id} after #{@deferral_alert_threshold} consecutive checks (#{inspect(reason)}).",
      issue: issue,
      reason: "GitHub dispatch authorization has been deferred for #{@deferral_alert_threshold} consecutive checks: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp alert_deferral_resolved(%Issue{id: id} = issue) do
    Signal.agent_alert(
      deferral_topic(id) <> ".resolved",
      "Dispatch authorization checks have recovered for issue #{issue.identifier || id}.",
      issue: issue,
      reason: "GitHub dispatch authorization is no longer deferred",
      needs_attention: false,
      severity: "info"
    )
  end

  defp deferral_topic(id), do: "ticket.#{id}.agent.attention.dispatch_authorization.deferred"

  defp bounded_alert_cache(alerted) when map_size(alerted) >= @max_cache_entries, do: %{}
  defp bounded_alert_cache(alerted), do: alerted

  defp alert_ambiguity(issue, reason) do
    Signal.agent_alert(
      "github.dispatch_authorization.ambiguous",
      "Dispatch denied for issue #{issue.identifier || issue.id}: label provenance could not be verified (#{inspect(reason)}).",
      issue: issue.identifier || issue.id,
      reason: "GitHub dispatch authorization requires verified trigger-label provenance: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning"
    )
  end

  # Deliberately a different alert name from the ambiguity alert: this ticket was
  # NOT refused on provenance. Its timeline could not be read inside Aiur's own
  # response cap even at the smallest page size, which is an Aiur limit to raise,
  # not a ticket to re-triage.
  defp alert_transport_limit(issue, {:transport_limit, reason}) do
    Signal.agent_alert(
      "github.dispatch_authorization.timeline_unreadable",
      "Dispatch deferred for issue #{issue.identifier || issue.id}: its GitHub timeline could not be " <>
        "read within Aiur's #{Timeline.max_response_bytes()}-byte response cap (#{inspect(reason)}). " <>
        "This is a transport limit, not a provenance denial.",
      issue: issue.identifier || issue.id,
      reason:
        "Timeline provenance was unreadable at every page size in #{inspect(Timeline.page_sizes())}: " <>
          "#{inspect(reason)}. Label provenance was never evaluated.",
      needs_attention: true,
      severity: "warning"
    )
  end
end
