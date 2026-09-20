defmodule Aiur.GitHub.DispatchAuthorization do
  @moduledoc false

  require Logger

  alias Aiur.{Alerts, Issue}
  alias Aiur.GitHub.{Config, Errors, StatePolicy, Transport}

  @cache_key {__MODULE__, :timeline_cache}
  # The timeline cache holds event lists — up to `@max_timeline_events` pruned
  # events per issue. `:persistent_term.put/2` triggers a global literal-area GC
  # across every process, so holding those lists there (and rewriting them on
  # every dispatch attempt) is exactly the failure this table avoids: ETS is
  # reference-counted and GC-agnostic. Only the small fingerprint/decision/alert
  # caches stay in `:persistent_term` (#2298 rework B4).
  @timeline_table :aiur_github_dispatch_authorization_timelines
  @max_cache_entries 1_000

  # A timeline page requests up to `per_page=100` events, each of which embeds
  # the full actor and label objects — and, for every `cross-referenced` event,
  # the *entire source issue including its body*. That last part is why 512 KiB
  # was not enough: page size scales with how much prose the referencing tickets
  # carry, not with the event count. A real ticket referenced 13 times measured
  # 777 KiB for 51 events and so deferred on every cycle forever, while a
  # less-referenced ticket in the same repo fetched in 158 KiB (#2749). The cap
  # punished exactly the well-documented, heavily-referenced tickets that sit on
  # a run's critical path.
  #
  # 4 MiB covers a hundred-times-referenced ticket and costs nothing when the
  # page is small, because the cap only bounds what the transport is willing to
  # read. It is a backstop now rather than the operative limit: a page that
  # still exceeds it is refetched at a smaller `per_page` (see
  # `@timeline_per_page_attempts`) instead of deferring authorization outright.
  @max_timeline_response_bytes 4_194_304

  # Successive `per_page` sizes tried when a page still comes back over the cap.
  # A truncated page is an inability to read *this page size*, not a terminal
  # verdict on the timeline: halving the page halves the embedded payload, so a
  # timeline no single 4 MiB page can carry is still readable in smaller slices.
  # Only when the smallest slice is still too large does the fetch defer.
  @timeline_per_page_attempts [100, 50, 25]

  # The provenance budget is a number of *events*, not a number of pages, so
  # shrinking `per_page` buys more requests rather than a shorter timeline.
  @max_timeline_events 400

  # Indefinite deferral used to be silent: the warning in `apply_label_decision`
  # goes to `aiur.log` and nowhere else, so a ticket whose timeline fetch keeps
  # failing sits undispatched cycle after cycle with nothing in the alert feed
  # an Executor actually reads. One deferral is routine (a rate limit, a
  # transport blip); the same issue deferring every cycle at a 60s cadence is an
  # operator problem. Alert once per streak — not once per cycle — and report
  # the recovery when authorization decides again (#2749).
  @deferral_alert_threshold 5

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

    if :ets.whereis(@timeline_table) != :undefined do
      :ets.delete_all_objects(@timeline_table)
    end

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
    Logger.warning(
      "GitHub dispatch authorization deferred issue_id=#{inspect(issue.id)} " <>
        "issue_identifier=#{inspect(issue.identifier)} reason=#{inspect(reason)} " <>
        "state=#{inspect(issue.state)}; ticket is not dispatched this cycle and no " <>
        "running agent is revoked (transient, not a provenance denial)"
    )

    note_deferral(issue, reason)
    %{issue | dispatch_authorized?: false, dispatch_authorization: :deferred}
  end

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
      base_url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{issue.id}/timeline"

      held = held_timeline(issue.id)

      case fetch_timeline(request_fun, token, base_url, held) do
        {:ok, events, new_etag, single_page?, per_page} ->
          store_timeline(issue.id, new_etag, events, single_page?, per_page)
          timeline_decision(issue, label, prefix, events)

        {:reused, events} ->
          timeline_decision(issue, label, prefix, events)

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

  # The only validator we hold belongs to page 1 of the timeline. A `304`
  # against it proves page 1 unchanged — and issue timelines are ordered
  # oldest-first, so page 1 is effectively immutable and a `304` there says
  # nothing about the later pages where new `labeled` events land. The held
  # timeline is therefore reusable on a `304` only when it was a *single page*
  # AND GitHub does not report a new page on the `304` (the single→multi
  # transition is exactly the staleness this must never serve). A multi-page
  # held timeline is refetched every cycle: its validator belongs to a page that
  # cannot move, so it can never buy an answer.
  defp fetch_timeline(request_fun, token, base_url, held),
    do: fetch_timeline(request_fun, token, base_url, held, @timeline_per_page_attempts)

  # Every page size was still over the cap. Only now is the truncation terminal
  # for this cycle, and even then it defers rather than denying.
  defp fetch_timeline(_request_fun, _token, _base_url, _held, []), do: {:error, :timeline_truncated}

  defp fetch_timeline(request_fun, token, base_url, held, [per_page | smaller]) do
    case timeline_pages(request_fun, token, base_url, held, per_page) do
      {:error, :timeline_page_too_large} ->
        Logger.warning(
          "GitHub timeline page exceeded #{@max_timeline_response_bytes} bytes at " <>
            "per_page=#{per_page}; retrying at a smaller page size " <>
            "(remaining=#{inspect(smaller)})"
        )

        # The held validator belongs to a page-1 URL at the previous size, so
        # the smaller retry starts from an unconditional fetch.
        fetch_timeline(request_fun, token, base_url, nil, smaller)

      other ->
        other
    end
  end

  defp timeline_pages(request_fun, token, base_url, held, per_page) do
    url = timeline_url(base_url, per_page)
    etag = if reusable?(held, per_page), do: held.etag, else: nil

    case request_fun.(timeline_request(url, token, etag)) do
      {:ok, %{status: 304} = response} ->
        timeline_not_modified(request_fun, token, base_url, held, etag, response, per_page)

      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        continue_timeline_pages(request_fun, token, page, response, page_budget(per_page), [], per_page)

      other ->
        timeline_fetch_error(other)
    end
  end

  defp timeline_url(base_url, per_page), do: "#{base_url}?per_page=#{per_page}"

  # Pages are a means, not the budget. Holding the *event* ceiling fixed means a
  # smaller `per_page` costs more requests instead of silently shortening the
  # timeline the provenance decision is read from.
  defp page_budget(per_page), do: max(div(@max_timeline_events, per_page), 1)

  # A `304` with no validator sent is a proxy answering a request that carried
  # none — not a page.
  defp timeline_not_modified(_request_fun, _token, _base_url, _held, nil, _response, _per_page),
    do: {:error, :timeline_unexpected_304}

  defp timeline_not_modified(request_fun, token, base_url, held, _etag, response, per_page) do
    if next_page?(response) do
      # Page 1 is unchanged but the timeline grew a page the held single page
      # cannot see (or the held timeline spanned pages whose newer content page 1
      # cannot vouch for). Refetch the whole timeline rather than answer from a
      # snapshot page 1 cannot confirm.
      timeline_pages(request_fun, token, base_url, nil, per_page)
    else
      {:reused, held.events}
    end
  end

  # Page 1 answered 200: capture its validator (the only one ever reusable,
  # because it belongs to the immutable head of the list) and follow the `Link`
  # pages. A single page answers `single_page?: true`, which is what makes a
  # future `304` trustworthy.
  defp continue_timeline_pages(request_fun, token, page, response, pages_left, events, per_page) do
    first_etag = response_etag(response, nil)
    events = events ++ prune_events(page)

    case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
      nil -> {:ok, events, first_etag, true, per_page}
      next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events, first_etag, per_page)
    end
  end

  defp fetch_timeline_pages(_request_fun, _token, _url, 0, _events, _first_etag, _per_page),
    do: {:error, :timeline_page_limit_exceeded}

  defp fetch_timeline_pages(request_fun, token, url, pages_left, events, first_etag, per_page) do
    case request_fun.(timeline_request(url, token, nil)) do
      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        events = events ++ prune_events(page)

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, events, first_etag, false, per_page}
          next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events, first_etag, per_page)
        end

      {:ok, %{status: 304}} ->
        # Pages after the first are unconditional, so a `304` here is a proxy
        # answering a request that carried no validator — not a page. Fail
        # closed rather than serve a truncated timeline.
        {:error, :timeline_unexpected_304}

      other ->
        timeline_fetch_error(other)
    end
  end

  # The transport clears the body and flags the response when it stops reading
  # at @max_timeline_response_bytes. That flag is the one signal that says
  # "smaller pages would fit", so it is classified apart from a merely malformed
  # 200 and is the only thing `fetch_timeline/5` retries on (#2749).
  defp timeline_fetch_error({:ok, %{status: 200, private: %{aiur_response_too_large: true}}}),
    do: {:error, :timeline_page_too_large}

  # A 200 whose body is not a JSON list means the page was truncated or was
  # otherwise malformed — not an HTTP failure. Name the real cause instead of
  # the self-contradictory `{:github, :http, %{status: 200}}` (#1454).
  defp timeline_fetch_error({:ok, %{status: 200}}), do: {:error, :timeline_truncated}

  defp timeline_fetch_error({:ok, %{status: status} = response}),
    do: {:error, {:timeline_fetch_failed, Errors.github_status_error(Map.put(response, :status, status))}}

  defp timeline_fetch_error({:error, reason}),
    do: {:error, {:timeline_fetch_failed, Errors.classify_error({:error, reason})}}

  defp timeline_fetch_error(_response), do: {:error, :invalid_timeline_response}

  defp timeline_request(url, token, etag) do
    request = %{
      method: :get,
      url: url,
      token: token,
      max_response_bytes: @max_timeline_response_bytes,
      caller: "dispatch_authorization"
    }

    if is_binary(etag) and etag != "", do: Map.put(request, :etag, etag), else: request
  end

  defp response_etag(response, fallback) do
    Transport.header(Map.get(response, :headers, []), "etag") || fallback
  end

  defp next_page?(response), do: not is_nil(Transport.parse_next_page_url(Map.get(response, :headers, [])))

  # The timeline cache is keyed by issue id and holds the validator for page 1,
  # the held events, and whether those events came from a single page — the only
  # case a page-1 `304` is allowed to answer.
  defp held_timeline(issue_id) when is_binary(issue_id) do
    case :ets.lookup(timeline_table(), issue_id) do
      [{^issue_id, held}] -> held
      [] -> nil
    end
  end

  defp held_timeline(_issue_id), do: nil

  defp store_timeline(issue_id, etag, events, single_page?, per_page) when is_binary(issue_id) do
    table = timeline_table()

    :ets.insert(
      table,
      {issue_id, %{etag: etag, events: events, single_page?: single_page?, per_page: per_page}}
    )

    if :ets.info(table, :size) > @max_cache_entries do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  defp store_timeline(_issue_id, _etag, _events, _single_page?, _per_page), do: :ok

  # A validator belongs to one page-1 URL, and `per_page` is part of that URL.
  # Reusing an etag captured at a different page size would send a conditional
  # request GitHub answers for a page the held events did not come from.
  defp reusable?(%{single_page?: true, etag: etag, events: events} = held, per_page)
       when is_binary(etag) and etag != "" and is_list(events),
       do: Map.get(held, :per_page) == per_page

  defp reusable?(_held, _per_page), do: false

  # Dispatch authorization reads exactly five fields per event: the event type,
  # the label name, the actor login, the created-at timestamp, and the id. The
  # timeline endpoint embeds the *full source issue* in every `cross-referenced`
  # event, which is payload no decision here ever consults. The endpoint has no
  # field selection, so the bytes arrive either way — but they do not have to be
  # retained: pruning at the fetch boundary keeps the ETS timeline cache
  # proportional to how many events a ticket has rather than to how much prose
  # the tickets referencing it carry (#2749).
  #
  # Non-map entries pass through untouched. `latest_label_event/2` rejects a
  # timeline containing one, and that check must still see what arrived.
  defp prune_events(page), do: Enum.map(page, &prune_event/1)

  defp prune_event(event) when is_map(event) do
    %{
      "id" => Map.get(event, "id"),
      "event" => Map.get(event, "event"),
      "type" => Map.get(event, "type"),
      "created_at" => Map.get(event, "created_at"),
      "label" => %{"name" => nested_field(event, "label", "name")},
      "actor" => %{"login" => nested_field(event, "actor", "login")}
    }
  end

  defp prune_event(event), do: event

  defp nested_field(event, key, inner) do
    case Map.get(event, key) do
      %{} = nested -> Map.get(nested, inner)
      _other -> nil
    end
  end

  defp timeline_table do
    case :ets.whereis(@timeline_table) do
      :undefined -> :ets.new(@timeline_table, [:named_table, :public, :set, read_concurrency: true])
      _other -> @timeline_table
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
      cache
      | fingerprints: Map.put(cache.fingerprints, fingerprint, event_id),
        decisions: Map.put(cache.decisions, {id, label, event_id}, decision)
    }

    # Deferral streaks survive a decision-cache overflow: they track "this issue
    # has not been dispatchable for N cycles", which a cache eviction says
    # nothing about, and dropping them would silence the alert forever on a busy
    # fleet.
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
    clear_deferrals(issue)
    maybe_alert_ambiguity(issue, reason)
    %{issue | dispatch_authorized?: false, dispatch_authorization: :denied}
  end

  defp maybe_alert_ambiguity(%Issue{id: id, updated_at: updated_at} = issue, reason)
       when is_binary(id) do
    alert_key = {id, updated_at, reason}
    cache = cache()

    unless Map.has_key?(cache.alerted, alert_key) do
      alerted =
        cache.alerted
        |> bounded_cache()
        |> Map.put(alert_key, true)

      :persistent_term.put(@cache_key, %{cache | alerted: alerted})
      alert_ambiguity(issue, reason)
    end
  end

  defp maybe_alert_ambiguity(issue, reason), do: alert_ambiguity(issue, reason)

  defp cache do
    :persistent_term.get(@cache_key, %{fingerprints: %{}, decisions: %{}, alerted: %{}, deferrals: %{}})
  end

  defp bounded_cache(entries) when map_size(entries) >= @max_cache_entries, do: %{}
  defp bounded_cache(entries), do: entries

  # Counts consecutive deferrals per issue so a stuck ticket becomes visible in
  # the alert feed instead of only in `aiur.log`. The streak is per issue rather
  # than per {issue, reason}: an issue that alternates between a rate limit and
  # a truncation is just as undispatchable as one that fails the same way twice,
  # and the alert reports whichever reason it is currently failing with.
  defp note_deferral(%Issue{id: id} = issue, reason) when is_binary(id) do
    cache = cache()
    streak = Map.get(cache.deferrals, id, %{count: 0, alerted?: false})
    count = streak.count + 1
    alert? = count >= @deferral_alert_threshold and not streak.alerted?

    deferrals =
      cache.deferrals
      |> bounded_cache()
      |> Map.put(id, %{count: count, alerted?: streak.alerted? or alert?})

    :persistent_term.put(@cache_key, %{cache | deferrals: deferrals})

    if alert?, do: alert_persistent_deferral(issue, reason, count)

    :ok
  end

  defp note_deferral(_issue, _reason), do: :ok

  # Any real decision — allow, deny, or an ambiguity verdict — ends the streak:
  # the fetch produced an answer, so whatever was blocking it has cleared. Only
  # a streak that actually alerted reports its recovery, so a ticket that
  # deferred twice and then dispatched stays silent in both directions.
  defp clear_deferrals(%Issue{id: id} = issue) when is_binary(id) do
    cache = cache()

    case Map.pop(cache.deferrals, id) do
      {nil, _remaining} ->
        :ok

      {streak, remaining} ->
        :persistent_term.put(@cache_key, %{cache | deferrals: remaining})
        if streak.alerted?, do: alert_deferral_resolved(issue, streak.count)
        :ok
    end
  end

  defp clear_deferrals(_issue), do: :ok

  defp alert_persistent_deferral(issue, reason, count) do
    identifier = issue.identifier || issue.id

    Alerts.emit_custom(
      "github.dispatch_authorization.deferred",
      "Issue #{identifier} has not been dispatched: authorization has deferred #{count} cycles in a row (#{inspect(reason)}).",
      issue: identifier,
      reason: "GitHub dispatch authorization could not be verified for #{count} consecutive cycles (#{inspect(reason)}); the ticket stays undispatched until the timeline fetch succeeds",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp alert_deferral_resolved(issue, count) do
    identifier = issue.identifier || issue.id

    Alerts.emit_custom(
      "github.dispatch_authorization.deferred.resolved",
      "Issue #{identifier} authorized again after #{count} deferred cycles.",
      issue: identifier,
      reason: "GitHub dispatch authorization recovered; the deferral streak cleared",
      needs_attention: false,
      severity: "info"
    )
  end

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
