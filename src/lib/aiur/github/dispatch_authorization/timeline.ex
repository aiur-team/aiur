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

    case fetch_timeline(request_fun, token, url, held, per_page) do
      {:ok, events, etag, single_page?, pages} ->
        {:ok, events, etag, single_page?, per_page, pages}

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

  # Every page keeps its own validator. Issue timelines are ordered
  # oldest-first, so a page-1 `304` says nothing about the later pages where new
  # `labeled` events land — but a `304` on each page in turn does: every page
  # GitHub vouches for is unchanged, and the walk still follows the `Link`
  # chain to the end. The one page whose `304` cannot be trusted is a *full*
  # last page: a new event opens a page after it while its own body, and so its
  # validator, stays the same. That page is always read unconditionally, which
  # also reports the new `rel="next"` link. Unchanged full pages are then free,
  # and a refetch of a busy ticket's timeline costs one billable page rather
  # than one per page.
  defp fetch_timeline(request_fun, token, url, held, per_page) do
    walk_timeline(request_fun, token, url, held_pages(held, url), page_budget(per_page), per_page, [])
  end

  defp walk_timeline(_request_fun, _token, _url, _held_pages, 0, _per_page, _pages), do: {:error, :timeline_page_limit_exceeded}

  defp walk_timeline(request_fun, token, url, held_pages, pages_left, per_page, pages) do
    held_page = Map.get(held_pages, url)
    etag = page_validator(held_page, per_page)

    case request_fun.(timeline_request(url, token, etag)) do
      {:ok, %{status: 304} = response} when is_binary(etag) ->
        page = Map.merge(held_page, %{next_url: next_page_url(response) || held_page.next_url, reused?: true})
        continue_timeline(request_fun, token, held_pages, pages_left, per_page, [page | pages])

      {:ok, %{status: 304}} ->
        # A `304` to a request that carried no validator is a proxy answering
        # — not a page. Fail closed rather than serve a truncated timeline.
        {:error, :timeline_unexpected_304}

      {:ok, %{status: 200, body: body} = response} when is_list(body) ->
        page = %{url: url, etag: response_etag(response, nil), events: prune_events(body), next_url: next_page_url(response), reused?: false}
        continue_timeline(request_fun, token, held_pages, pages_left, per_page, [page | pages])

      other ->
        timeline_fetch_error(other)
    end
  end

  defp continue_timeline(_request_fun, _token, _held_pages, _pages_left, _per_page, [%{next_url: nil} | _rest] = pages),
    do: finish_timeline(Enum.reverse(pages))

  defp continue_timeline(request_fun, token, held_pages, pages_left, per_page, [%{next_url: next_url} | _rest] = pages),
    do: walk_timeline(request_fun, token, next_url, held_pages, pages_left - 1, per_page, pages)

  # Every page answered `304`, so the held timeline — validators, page
  # boundaries and all — is exactly what GitHub would return.
  defp finish_timeline(pages) do
    events = Enum.flat_map(pages, & &1.events)

    if Enum.all?(pages, & &1.reused?) do
      {:reused, events}
    else
      meta = Enum.map(pages, &%{url: &1.url, etag: &1.etag, count: length(&1.events), next_url: &1.next_url})
      {:ok, events, hd(pages).etag, length(pages) == 1, meta}
    end
  end

  # A held page may be revalidated unless it is a full last page (see
  # `fetch_timeline/5`).
  defp page_validator(%{etag: etag, events: events, next_url: next_url}, per_page)
       when is_binary(etag) and etag != "" and (is_binary(next_url) or length(events) < per_page),
       do: etag

  defp page_validator(_held_page, _per_page), do: nil

  # The held timeline, keyed by page URL. A held page list that does not add up
  # to the held events is not evidence of anything, so it holds no validators.
  defp held_pages(%{pages: pages, events: events}, _first_url) when is_list(pages) and is_list(events) do
    if Enum.sum(Enum.map(pages, & &1.count)) == length(events) do
      pages
      |> Enum.map_reduce(events, fn %{url: url, etag: etag, count: count, next_url: next_url}, remaining ->
        {{url, %{url: url, etag: etag, events: Enum.take(remaining, count), next_url: next_url}}, Enum.drop(remaining, count)}
      end)
      |> elem(0)
      |> Map.new()
    else
      %{}
    end
  end

  # A held single page with no page list is its own page 1.
  defp held_pages(%{single_page?: true, etag: etag, events: events}, first_url) when is_list(events),
    do: %{first_url => %{url: first_url, etag: etag, events: events, next_url: nil}}

  defp held_pages(_held, _first_url), do: %{}

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

  defp next_page_url(response), do: Access.parse_next_page_url(Map.get(response, :headers, []))

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
