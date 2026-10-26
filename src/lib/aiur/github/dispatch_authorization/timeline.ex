defmodule Aiur.GitHub.DispatchAuthorization.Timeline do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{Access, LocalProvenance, TimelineCache}
  alias Aiur.GitHub.DispatchAuthorization.TimelineFetch
  alias Aiur.Issue

  # Timeline page size in BYTES is driven by content Aiur does not control: each
  # event embeds the full actor, label, and often issue objects — ~2.5–3.5 KiB
  # per event on quiet timelines, but 5.75 KiB per event on aiur-team/khala#257,
  # whose Codex-401 retry churn and label swaps pushed its `per_page=100` page 1
  # to 575,125 bytes. Past the response cap the transport clears the body, the
  # `is_list/1` guard fails, and the fetch reports `:timeline_truncated`. That is
  # correctly not provenance evidence, so dispatch fails closed — but the limit is
  # re-hit on *every* fetch, so the ticket became permanently undispatchable: no
  # relabel by a trusted user and no daemon restart could clear it.
  #
  # #1454 answered the same failure by raising the cap (64 KiB -> 512 KiB), which
  # only moved the ceiling. So the cap stays where it is and the REQUEST is made
  # resilient to it instead:
  #
  #   * `@timeline_page_sizes` is a ladder of `per_page` values, tried in order.
  #     The default (50) is sized so that even khala#257's page 1 is 262,218
  #     bytes — half the cap — rather than sized to the cap's edge.
  #   * On `:timeline_truncated` the whole timeline is refetched at the next,
  #     smaller page size before the failure is believed. That recovers tickets
  #     which are *already* oversized without touching the healthy path.
  #   * `@max_timeline_events` holds total provenance reach constant regardless of
  #     page size, so a smaller page buys resilience and never costs coverage:
  #     the page budget is derived, not fixed (4x100 before; 8x50 or 20x20 now —
  #     400 events either way).
  @max_timeline_response_bytes 524_288
  @timeline_page_sizes [50, 20]
  @max_timeline_events 400

  @spec page_sizes() :: [pos_integer()]
  def page_sizes, do: @timeline_page_sizes

  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_timeline_response_bytes

  @spec fetch((map() -> term()), String.t(), String.t(), String.t(), Issue.t(), keyword()) :: term()
  def fetch(request_fun, token, owner, repo, issue, opts) do
    TimelineFetch.run(&fetch_timeline_ladder/6, [request_fun, token, owner, repo, issue, TimelineCache.page_sizes(owner, repo, issue.id, @timeline_page_sizes)], opts)
  end

  # Walk the `per_page` ladder: a truncated page is a statement about this page
  # SIZE, not about the timeline, so refetch the same timeline in smaller pages
  # before giving up. Only truncation retries — every other failure (rate limit,
  # transport outage, unexpected 304, page budget) is returned as-is, because a
  # smaller page cannot fix any of them. When the last rung still truncates, the
  # evidence is genuinely unobtainable and the caller defers, fail-closed, with
  # the page size named so the denial is legible as a transport limit rather than
  # as a provenance verdict.
  defp fetch_timeline_ladder(request_fun, token, owner, repo, issue, [per_page | smaller]) do
    url = timeline_url(owner, repo, issue.id, per_page)
    held = TimelineCache.get(owner, repo, issue.id, per_page)

    case fetch_timeline(request_fun, token, url, held, page_budget(per_page)) do
      {:ok, events, etag, single_page?} ->
        {:ok, events, etag, single_page?, per_page}

      {:error, :timeline_truncated} when smaller != [] ->
        Logger.warning(
          "GitHub dispatch authorization timeline page truncated issue_id=#{inspect(issue.id)} " <>
            "issue_identifier=#{inspect(issue.identifier)} per_page=#{per_page} " <>
            "max_response_bytes=#{@max_timeline_response_bytes}; refetching at per_page=#{hd(smaller)}"
        )

        fetch_timeline_ladder(request_fun, token, owner, repo, issue, smaller)

      {:error, :timeline_truncated} ->
        {:error, {:timeline_truncated, per_page}}

      other ->
        other
    end
  end

  defp timeline_url(owner, repo, issue_id, per_page),
    do: "#{Access.base_url()}/repos/#{owner}/#{repo}/issues/#{issue_id}/timeline?per_page=#{per_page}"

  # Total event reach is the invariant, not the page count: a smaller page just
  # means more of them.
  defp page_budget(per_page), do: max(div(@max_timeline_events, per_page), 1)

  # The only validator we hold belongs to page 1 of the timeline. A `304`
  # against it proves page 1 unchanged — and issue timelines are ordered
  # oldest-first, so page 1 is effectively immutable and a `304` there says
  # nothing about the later pages where new `labeled` events land. The held
  # timeline is therefore reusable on a `304` only when it was a *single page*
  # AND GitHub does not report a new page on the `304` (the single→multi
  # transition is exactly the staleness this must never serve). A multi-page
  # held timeline is refetched every cycle: its validator belongs to a page that
  # cannot move, so it can never buy an answer.
  defp fetch_timeline(request_fun, token, url, held, pages) do
    etag = if reusable?(held), do: held.etag, else: nil

    case request_fun.(timeline_request(url, token, etag)) do
      {:ok, %{status: 304} = response} ->
        timeline_not_modified(request_fun, token, url, held, etag, response, pages)

      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        continue_timeline_pages(request_fun, token, page, response, pages, [])

      other ->
        timeline_fetch_error(other)
    end
  end

  # A `304` with no validator sent is a proxy answering a request that carried
  # none — not a page.
  defp timeline_not_modified(_request_fun, _token, _url, _held, nil, _response, _pages),
    do: {:error, :timeline_unexpected_304}

  defp timeline_not_modified(request_fun, token, url, held, _etag, response, pages) do
    if next_page?(response) do
      # Page 1 is unchanged but the timeline grew a page the held single page
      # cannot see (or the held timeline spanned pages whose newer content page 1
      # cannot vouch for). Refetch the whole timeline rather than answer from a
      # snapshot page 1 cannot confirm.
      fetch_timeline(request_fun, token, url, nil, pages)
    else
      {:reused, held.events}
    end
  end

  # Page 1 answered 200: capture its validator (the only one ever reusable,
  # because it belongs to the immutable head of the list) and follow the `Link`
  # pages. A single page answers `single_page?: true`, which is what makes a
  # future `304` trustworthy.
  defp continue_timeline_pages(request_fun, token, page, response, pages_left, events) do
    first_etag = response_etag(response, nil)

    case Access.parse_next_page_url(Map.get(response, :headers, [])) do
      nil -> {:ok, events ++ prune_events(page), first_etag, true}
      next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events ++ prune_events(page), first_etag)
    end
  end

  defp fetch_timeline_pages(_request_fun, _token, _url, 0, _events, _first_etag), do: {:error, :timeline_page_limit_exceeded}

  defp fetch_timeline_pages(request_fun, token, url, pages_left, events, first_etag) do
    case request_fun.(timeline_request(url, token, nil)) do
      {:ok, %{status: 200, body: page} = response} when is_list(page) ->
        case Access.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, events ++ prune_events(page), first_etag, false}
          next_url -> fetch_timeline_pages(request_fun, token, next_url, pages_left - 1, events ++ prune_events(page), first_etag)
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

  # A 200 whose body is not a JSON list means the page was truncated at
  # @max_timeline_response_bytes by the transport (the body becomes ""), or was
  # otherwise malformed — not an HTTP failure. Name the real cause instead of
  # the self-contradictory `{:github, :http, %{status: 200}}` (#1454).
  defp timeline_fetch_error({:ok, %{status: 200}}), do: {:error, :timeline_truncated}

  defp timeline_fetch_error({:ok, %{status: status} = response}),
    do: {:error, {:timeline_fetch_failed, Access.github_status_error(Map.put(response, :status, status))}}

  defp timeline_fetch_error({:error, reason}),
    do: {:error, {:timeline_fetch_failed, Access.classify_error({:error, reason})}}

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
    Access.header(Map.get(response, :headers, []), "etag") || fallback
  end

  defp next_page?(response), do: not is_nil(Access.parse_next_page_url(Map.get(response, :headers, [])))

  defp reusable?(%{single_page?: true, etag: etag, events: events})
       when is_binary(etag) and etag != "" and is_list(events),
       do: true

  defp reusable?(_held), do: false

  @spec decision(Issue.t(), String.t(), String.t(), list()) :: tuple()
  def decision(issue, label, prefix, events) do
    case latest_label_event(events, label) do
      %{id: event_id, actor: actor} ->
        if is_binary(actor) do
          decision = {:verified, actor, event_id, prefix_label_appliers(events, prefix), LocalProvenance.label_actors(events, prefix)}
          decision
        else
          {:ambiguous, :missing_timeline_actor}
        end

      :missing ->
        incomplete_label_decision(issue, :missing_label_event)

      :invalid ->
        incomplete_label_decision(issue, :missing_label_event_id)
    end
  end

  # A newly created todo issue can precede indexing of its creation-time
  # label event. For an active or rework ticket, the same missing evidence may
  # follow an untrusted relabel; keep the revocation verdict for those states.
  defp incomplete_label_decision(%Issue{state: "todo"}, reason), do: {:deferred, reason}
  defp incomplete_label_decision(_issue, reason), do: {:ambiguous, reason}

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

  defp prune_events(events) do
    Enum.map(events, fn
      event when is_map(event) ->
        Map.take(event, ["id", "event", "type", "created_at", "label", "actor"])

      other ->
        other
    end)
  end
end
