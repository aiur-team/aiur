defmodule Aiur.GitHub.DispatchAuthorization do
  @moduledoc false

  require Logger

  alias Aiur.{Alerts, Issue}
  alias Aiur.GitHub.{Config, Errors, StatePolicy, Transport}

  @cache_key {__MODULE__, :timeline_cache}
  @max_cache_entries 1_000

  # A timeline page requests up to `per_page=100` events (see fetch_decision),
  # each of which embeds the full actor, label, and often issue objects
  # (measured ~2.5–3.5 KiB per event on real timelines). 512 KiB holds a full
  # 100-event page with headroom; the previous 64 KiB cap truncated real
  # timelines at ~20 events, which failed the `is_list/1` guard and was
  # misreported as an HTTP error with status 200 (#1454).
  @max_timeline_response_bytes 524_288
  @max_timeline_pages 4

  @spec authorize(Issue.t(), String.t(), String.t(), String.t(), keyword()) :: Issue.t()
  def authorize(issue, owner, repo, prefix, opts \\ [])

  def authorize(%Issue{state_labels: [_, _ | _] = state_labels} = issue, _owner, _repo, _prefix, _opts) do
    deny_ambiguous(issue, {:contradictory_state_labels, state_labels})
  end

  # SECURITY INVARIANT — provenance of the TRIGGER LABEL is the only thing that
  # authorizes dispatch. There is deliberately no creator short-circuit.
  #
  # There used to be one: an issue whose creator was in `allowed_users` was
  # dispatched with no label check at all. Agents create issues with that same
  # credential, so an agent could file a ticket, label it `agent:todo`, and have
  # it dispatched with no human anywhere in the loop — a self-sustaining work
  # queue. It also meant that for any trusted-creator issue, a label applied by
  # an outsider (or no verifiable `labeled` event at all) still dispatched.
  #
  # Who *filed* a ticket says nothing about whether anyone decided it should
  # run. Requiring the verified label applier costs one timeline fetch per
  # issue — already cached per `{id, label, updated_at}` — and makes "an actor
  # in `allowed_users` moved this into a dispatch state" the single, auditable
  # precondition. If you reintroduce a short-circuit, agent-filed work becomes
  # self-authorizing again.
  def authorize(%Issue{} = issue, owner, repo, prefix, opts) do
    authorize_label_applier(issue, owner, repo, prefix, allowed_users(opts), opts)
  end

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
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
  defp apply_label_decision({:verified, actor, event_id, prefix_appliers}, issue, allowed_users, opts) do
    triaged_by = Enum.find(prefix_appliers, &member?(allowed_users, &1))

    {authorized?, source} =
      cond do
        member?(allowed_users, actor) -> {true, "label_applier"}
        aiur_actor?(actor, opts) and not is_nil(triaged_by) -> {true, "prior_triage:#{triaged_by}"}
        true -> {false, "label_applier"}
      end

    log_decision(
      if(authorized?, do: :allow, else: :deny),
      issue,
      source,
      actor,
      event_id
    )

    %{issue | dispatch_authorized?: authorized?}
  end

  defp apply_label_decision({:ambiguous, reason}, issue, _allowed_users, _opts), do: deny_ambiguous(issue, reason)

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
    request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    token = Keyword.get(opts, :token, Config.token())

    if is_binary(token) and token != "" do
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue.id}/timeline?per_page=100"

      held = held_timeline(issue.id)
      etag = if is_map(held), do: held.etag, else: nil

      case fetch_timeline_pages(request_fun, token, url, @max_timeline_pages, [], etag) do
        {:ok, events, new_etag} ->
          store_timeline(issue.id, new_etag, events)
          timeline_decision(issue, label, prefix, events)

        {:not_modified, _etag} ->
          timeline_decision_or_retry(issue, label, prefix, held, request_fun, token, url)

        {:error, reason} ->
          {:ambiguous, reason}
      end
    else
      {:ambiguous, :missing_github_token}
    end
  end

  # A `304` is only reusable while the decision cache still holds the timeline it
  # revalidated. When it does, the decision is recomputed from the held events —
  # the label provenance has not changed, so the decision is the same one the
  # fingerprint miss was about to re-derive. When nothing is held the request was
  # spent for nothing, so retry once unconditionally rather than return an empty
  # answer.
  defp timeline_decision_or_retry(issue, label, prefix, %{events: events}, _request_fun, _token, _url)
       when is_list(events) do
    timeline_decision(issue, label, prefix, events)
  end

  defp timeline_decision_or_retry(issue, label, prefix, _held, request_fun, token, url) do
    case fetch_timeline_pages(request_fun, token, url, @max_timeline_pages, [], nil) do
      {:ok, events, new_etag} ->
        store_timeline(issue.id, new_etag, events)
        timeline_decision(issue, label, prefix, events)

      {:error, reason} ->
        {:ambiguous, reason}
    end
  end

  defp held_timeline(issue_id) when is_binary(issue_id), do: Map.get(cache().timelines, issue_id)
  defp held_timeline(_issue_id), do: nil

  defp store_timeline(issue_id, etag, events) when is_binary(issue_id) do
    cache = cache()
    timelines = Map.put(cache.timelines, issue_id, %{etag: etag, events: events})
    timelines = if map_size(timelines) > @max_cache_entries, do: %{}, else: timelines
    :persistent_term.put(@cache_key, %{cache | timelines: timelines})
  end

  defp store_timeline(_issue_id, _etag, _events), do: :ok

  defp fetch_timeline_pages(_request_fun, _token, _url, 0, _events, _etag), do: {:error, :timeline_page_limit_exceeded}

  defp fetch_timeline_pages(request_fun, token, url, pages_left, events, etag) do
    request = %{
      method: :get,
      url: url,
      token: token,
      max_response_bytes: @max_timeline_response_bytes,
      caller: "dispatch_authorization"
    }

    request = if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request

    case request_fun.(request) do
      {:ok, %{status: 304} = response} ->
        {:not_modified, Transport.header(Map.get(response, :headers, []), "etag") || etag}

      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        retained = Transport.header(Map.get(response, :headers, []), "etag") || etag

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, events ++ page, retained}
          next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events ++ page, retained)
        end

      {:ok, %{status: 200}} ->
        # A 200 whose body is not a JSON list means the page was truncated at
        # @max_timeline_response_bytes by the transport (the body becomes ""),
        # or was otherwise malformed — not an HTTP failure. Name the real cause
        # instead of the self-contradictory `{:github, :http, %{status: 200}}`
        # (#1454).
        {:error, :timeline_truncated}

      {:ok, %{status: status} = response} ->
        {:error, {:timeline_fetch_failed, Errors.github_status_error(Map.put(response, :status, status))}}

      {:error, reason} ->
        {:error, {:timeline_fetch_failed, Errors.classify_error({:error, reason})}}

      _ ->
        {:error, :invalid_timeline_response}
    end
  end

  defp timeline_decision(issue, label, prefix, events) do
    case latest_label_event(events, label) do
      %{id: event_id, actor: actor} ->
        decision =
          if is_binary(actor),
            do: {:verified, actor, event_id, prefix_label_appliers(events, prefix)},
            else: {:ambiguous, :missing_timeline_actor}

        cache_decision(issue, label, event_id, decision)
        decision

      :missing ->
        decision = {:ambiguous, :missing_label_event}
        cache_decision(issue, label, "missing", decision)
        decision

      :invalid ->
        decision = {:ambiguous, :missing_label_event_id}
        cache_decision(issue, label, "invalid", decision)
        decision
    end
  end

  # Every actor who has ever applied a `<prefix>:*` state label to this issue.
  # This is the evidence that someone put the ticket into the agent pipeline,
  # and it is what an Aiur-applied state transition carries forward (see
  # `apply_label_decision/4`). The list is kept as raw logins rather than a
  # boolean so membership is evaluated against the CURRENT `allowed_users` on
  # every call — a login removed from the allowlist stops conferring trust even
  # while the timeline decision is still cached.
  defp prefix_label_appliers(events, prefix) do
    label_prefix = String.downcase(prefix) <> ":"

    events
    |> Enum.filter(fn event ->
      is_map(event) and
        (Map.get(event, "event") || Map.get(event, "type")) == "labeled" and
        prefixed_label?(get_in(event, ["label", "name"]), label_prefix)
    end)
    |> Enum.map(&get_in(&1, ["actor", "login"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp prefixed_label?(name, label_prefix) when is_binary(name),
    do: name |> String.trim() |> String.downcase() |> String.starts_with?(label_prefix)

  defp prefixed_label?(_name, _label_prefix), do: false

  defp latest_label_event(events, label) do
    if Enum.all?(events, &is_map/1), do: matching_label_event(events, label), else: :invalid
  end

  defp matching_label_event(events, label) do
    events
    |> Enum.reduce_while({:ok, []}, &collect_matching_event(&1, label, &2))
    |> latest_matching_event()
  end

  defp collect_matching_event(event, label, {:ok, matching}) do
    if labeled_with_name?(event, label) do
      case event_sort_key(event) do
        {:ok, sort_key} -> {:cont, {:ok, [{sort_key, event} | matching]}}
        :error -> {:halt, :invalid}
      end
    else
      {:cont, {:ok, matching}}
    end
  end

  defp latest_matching_event({:ok, []}), do: :missing

  defp latest_matching_event({:ok, matching}) do
    {_sort_key, %{"id" => id} = event} = Enum.max_by(matching, &elem(&1, 0))
    %{id: to_string(id), actor: get_in(event, ["actor", "login"])}
  end

  defp latest_matching_event(:invalid), do: :invalid

  defp labeled_with_name?(event, label) do
    (Map.get(event, "event") || Map.get(event, "type")) == "labeled" and
      label_matches?(get_in(event, ["label", "name"]), label)
  end

  defp event_sort_key(%{"created_at" => created_at, "id" => id}) when is_binary(created_at) do
    with {:ok, timestamp, _offset} <- DateTime.from_iso8601(created_at),
         event_id when is_integer(event_id) <- event_id_sort_key(id) do
      {:ok, {DateTime.to_unix(timestamp, :microsecond), event_id}}
    else
      _ -> :error
    end
  end

  defp event_sort_key(_event), do: :error

  defp event_id_sort_key(id) when is_integer(id) and id >= 0, do: id

  defp event_id_sort_key(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp event_id_sort_key(_id), do: nil

  defp label_matches?(event_label, label) when is_binary(event_label),
    do: String.downcase(String.trim(event_label)) == String.downcase(label)

  defp label_matches?(_event_label, _label), do: false

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
      timelines: cache.timelines,
      alerted: cache.alerted
    }

    :persistent_term.put(
      @cache_key,
      if(map_size(updated.decisions) > @max_cache_entries,
        do: %{fingerprints: %{}, decisions: %{}, timelines: %{}, alerted: %{}},
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
    %{issue | dispatch_authorized?: false}
  end

  defp maybe_alert_ambiguity(%Issue{id: id, updated_at: updated_at} = issue, reason)
       when is_binary(id) do
    alert_key = {id, updated_at, reason}
    cache = cache()

    unless Map.has_key?(cache.alerted, alert_key) do
      alerted =
        cache.alerted
        |> bounded_alert_cache()
        |> Map.put(alert_key, true)

      :persistent_term.put(@cache_key, %{cache | alerted: alerted})
      alert_ambiguity(issue, reason)
    end
  end

  defp maybe_alert_ambiguity(issue, reason), do: alert_ambiguity(issue, reason)

  defp cache do
    :persistent_term.get(@cache_key, %{fingerprints: %{}, decisions: %{}, timelines: %{}, alerted: %{}})
  end

  defp bounded_alert_cache(alerted) when map_size(alerted) >= @max_cache_entries, do: %{}
  defp bounded_alert_cache(alerted), do: alerted

  defp alert_ambiguity(issue, reason) do
    Alerts.emit_custom(
      "github.dispatch_authorization.ambiguous",
      "Dispatch denied for issue #{issue.identifier || issue.id}: label provenance could not be verified (#{inspect(reason)}).",
      issue: issue.identifier || issue.id,
      reason: "GitHub dispatch authorization requires verified trigger-label provenance: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning"
    )
  end
end
