defmodule Aiur.BuildOrder.History.Export do
  @moduledoc """
  One page of past and open tickets, read from local stores only, for the
  history classification backfill.

  Every fact comes from History, EpicOverrides, Features, the configured
  general epics, and issue bodies ResourceStore still holds. Nothing here asks
  GitHub. A fact the stores do not hold is left out of the record and named in
  its `unknown` list; it is never sent as `""`, `[]`, `0` or `nil`.

  Records are final, so `aiur history export` and an agent tool calling
  `page/1` cannot render one ticket differently.
  """

  alias Aiur.BuildOrder.{Epic, EpicOverrides, Features, History, Index, ProviderHealth}
  alias Aiur.BuildOrder.Index.Catalogue
  alias Aiur.DisplaySanitizer
  alias Aiur.GitHub.ResourceStore

  @default_limit 200
  @max_limit 500
  @title_limit 256
  @label_limit 100
  @excerpt_limit 1_600
  @body_byte_limit 262_144
  @window_chars 2 * @excerpt_limit
  @sanitize [redact_urls: true, redact_environment: true]

  @doc """
  Builds one page. Options: `:unsorted` (only tickets the resolver placed in
  `unsorted` by default), `:after` (ticket number cursor, default 0), `:limit`
  (1..#{@max_limit}, default #{@default_limit}), `:now`, and the injectable readers
  `:history`, `:overrides`, `:features`, `:epics` and `:issue_body`.

  Fails closed when History, EpicOverrides or Features is unavailable, or when
  History has not finished its backfill: a partial list would let a
  classifier skip tickets it cannot see.
  """
  @spec page(keyword()) :: {:ok, map()} | {:error, String.t()}
  def page(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, request} <- request(opts),
         {:ok, history} <- history(reader(opts, :history, &History.snapshot/0).()),
         {:ok, overrides, overrides_health} <- overrides(reader(opts, :overrides, &EpicOverrides.all/0).()),
         {:ok, registry} <- features(reader(opts, :features, &Features.snapshot/0).()),
         {:ok, general} <- epics(reader(opts, :epics, &configured_epics/0).()) do
      parts = %{history: {:ok, history}, resolved_history: history.rows, features: {:ok, registry}, overrides: {:ok, overrides, overrides_health}}
      context = %{general: general, features: Map.new(registry.features, fn {slug, feature} -> {slug, Enum.map(feature.epics, & &1.key)} end)}
      resolved = Enum.map(history.rows, fn {number, row} -> {number, row, Epic.resolve(Index.resolver_context(parts, number), context)} end)
      matching = resolved |> Enum.filter(&selected?(request, &1)) |> Enum.sort_by(&elem(&1, 0))
      {page, rest} = matching |> Enum.filter(&(elem(&1, 0) > request.after)) |> Enum.split(request.limit)
      body_reader = reader(opts, :issue_body, &held_issue/1)
      records = Enum.map(page, fn {number, row, resolution} -> record(number, row, resolution, owner(registry, number), body_reader.(number), now) end)

      {:ok,
       %{
         tickets: records,
         next_after: if(rest == [] or page == [], do: nil, else: page |> List.last() |> elem(0)),
         matching_total: length(matching),
         unresolved_total: Enum.count(resolved, fn {_number, _row, resolution} -> resolution.source == "unknown" end),
         sources: %{
           history: source(history.health, now),
           epic_overrides: source(overrides_health, now),
           features: source(registry.health, now),
           issue_bodies: bodies(records)
         }
       }}
    end
  end

  defp reader(opts, key, default), do: Keyword.get(opts, key, default)

  # The agent tool reaches this module without the launcher's argument checks.
  defp request(opts) do
    unsorted = Keyword.get(opts, :unsorted, false)
    after_number = Keyword.get(opts, :after, 0)
    limit = Keyword.get(opts, :limit, @default_limit)

    cond do
      not is_boolean(unsorted) -> {:error, "unsorted must be true or false"}
      not (is_integer(after_number) and after_number >= 0) -> {:error, "after needs a non-negative integer"}
      not (is_integer(limit) and limit in 1..@max_limit) -> {:error, "limit needs an integer from 1 to #{@max_limit}"}
      true -> {:ok, %{unsorted: unsorted, after: after_number, limit: limit}}
    end
  end

  defp history({:ok, %{rows: rows, health: %ProviderHealth{complete?: true}} = snapshot}) when is_map(rows), do: {:ok, snapshot}
  defp history({:ok, %{health: %ProviderHealth{}}}), do: {:error, "history backfill incomplete; run after the one-time backfill finishes"}
  defp history(other), do: {:error, "history unavailable (#{failure(other)})"}

  defp overrides({:ok, overrides, %ProviderHealth{} = health}) when is_map(overrides), do: {:ok, overrides, health}
  defp overrides(other), do: {:error, "epic overrides unavailable (#{failure(other)})"}

  defp features({:ok, %{owners: owners, features: features, health: %ProviderHealth{}} = registry}) when is_map(owners) and is_map(features), do: {:ok, registry}
  defp features(other), do: {:error, "features unavailable (#{failure(other)})"}

  defp epics({:ok, general}) when is_list(general), do: {:ok, general}
  defp epics(other), do: {:error, "epic config unavailable (#{failure(other)})"}

  defp failure({:error, %ProviderHealth{failure: failure}}) when is_atom(failure) and not is_nil(failure), do: failure
  defp failure({:error, %ProviderHealth{state: state}}), do: state
  defp failure({:error, reason}) when is_atom(reason), do: reason
  defp failure(_other), do: :invalid_read

  defp configured_epics, do: Catalogue.general(%{settings: Aiur.Config.settings()})

  defp held_issue(number), do: ResourceStore.fetch(ResourceStore.key_for_repo(:issue, Aiur.Tracker.project_identity(), number))

  # Unsorted means the resolver fell through to its default. A ticket already
  # given an override or a feature has another source, so a rerun resumes.
  defp selected?(%{unsorted: false}, _resolved), do: true
  defp selected?(%{unsorted: true}, {_number, _row, resolution}), do: resolution.key == "unsorted" and resolution.source == "default"

  defp owner(registry, number) do
    case Map.get(registry.owners, number) do
      %{feature: slug} -> slug
      _none -> nil
    end
  end

  defp record(number, row, resolution, feature, held, now) do
    lifecycle = row.lifecycle

    {record, unknown} =
      {%{number: number, epic: %{key: resolution.key, source: resolution.source}, feature: feature}, []}
      |> fact(:state, known(lifecycle.state))
      |> fact(:state_reason, nullable(lifecycle.state_reason))
      |> fact(:title, text(row.title, @title_limit))
      |> fact(:labels, labels(row.labels))
      |> fact(:labels_complete, boolean(row.labels_complete))
      |> fact(:pr_number, nullable(row.pr_number))
      |> fact(:body, body(held, now))
      |> fact(:observed_at, observed(row.observed_at))

    Map.put(record, :unknown, Enum.reverse(unknown))
  end

  defp fact({record, unknown}, key, {:ok, value}), do: {Map.put(record, key, value), unknown}
  defp fact({record, unknown}, key, {:ok, value, missing}), do: {Map.put(record, key, value), Enum.reverse(missing) ++ unknown}
  defp fact({record, unknown}, key, :unknown), do: {record, [Atom.to_string(key) | unknown]}

  defp known(value) when value in [:unknown, nil], do: :unknown
  defp known(value), do: {:ok, value}
  defp nullable(:none), do: {:ok, nil}
  defp nullable(value), do: known(value)
  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: :unknown
  defp observed(%DateTime{} = at), do: {:ok, at}
  defp observed(_value), do: :unknown

  defp text(value, limit) when is_binary(value) do
    case DisplaySanitizer.sanitize_projection(value, limit, @sanitize) do
      {:ok, text, _truncated?} -> {:ok, text}
      :error -> :unknown
    end
  end

  defp text(_value, _limit), do: :unknown

  defp labels(labels) when is_list(labels) do
    {:ok, labels |> Enum.flat_map(&label/1) |> Enum.sort()}
  end

  defp labels(_labels), do: :unknown

  defp label(value) do
    case text(value, @label_limit) do
      {:ok, ""} -> []
      {:ok, text} -> [text]
      :unknown -> []
    end
  end

  # GitHub sends `"body": null` for an empty description: a known empty body.
  defp body({:ok, %{data: %{"body" => nil}} = entry}, now), do: body({:ok, %{entry | data: %{"body" => ""}}}, now)

  defp body({:ok, %{data: %{"body" => body}} = entry}, now) when is_binary(body) and byte_size(body) <= @body_byte_limit do
    {window, cut?} = window(body)

    case DisplaySanitizer.sanitize_projection(window, @excerpt_limit, @sanitize) do
      {:ok, excerpt, truncated?} ->
        {freshness, missing} = fetched(Map.get(entry, :fetched_at_ms), now)
        {:ok, Map.merge(%{excerpt: excerpt, truncated: truncated? or cut?}, freshness), missing}

      :error ->
        :unknown
    end
  end

  defp body(_held, _now), do: :unknown

  # Sanitising costs about 5 ms per KB, and ticket bodies here run to 50 KB, so
  # a page of whole bodies would outlast the 10 s control RPC. Only the head
  # can reach the excerpt, so sanitise twice the excerpt, cut at a line (or
  # word) boundary so no line is split. Constructs the cut leaves open, such as
  # a private key block or a credential element, are redacted to the end of
  # the window by the sanitiser's own end-of-input rules.
  defp window(body) when byte_size(body) <= @window_chars, do: {body, false}

  defp window(body) do
    head = String.slice(body, 0, @window_chars)
    minimum_cut = head |> String.slice(0, @excerpt_limit) |> byte_size()
    cut = Enum.find([last_boundary(head, "\n"), last_boundary(head, " ")], &(&1 > minimum_cut))

    cond do
      head == body -> {body, false}
      cut -> {binary_part(head, 0, cut), true}
      true -> {head, true}
    end
  end

  defp last_boundary(head, separator) do
    case :binary.matches(head, separator) do
      [] -> 0
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp fetched(at_ms, now) when is_integer(at_ms) do
    {%{observed_at: DateTime.from_unix!(at_ms, :millisecond), age_ms: max(DateTime.to_unix(now, :millisecond) - at_ms, 0)}, []}
  end

  defp fetched(_at_ms, _now), do: {%{}, ["body.observed_at", "body.age_ms"]}

  defp bodies(records) do
    held = Enum.count(records, &Map.has_key?(&1, :body))
    of = length(records)

    state =
      cond do
        held == of -> :available
        held == 0 -> :none_held
        true -> :partial
      end

    %{state: state, held: held, of: of, retention_hours: div(ResourceStore.retention_ms(), 3_600_000)}
  end

  # Same entry shape as `Aiur.BuildOrdersCLI` sources, so both commands report
  # observation age the same way.
  defp source(%ProviderHealth{} = health, now) do
    %{
      state: state(health.state),
      observed_at: health.observed_at,
      age_ms: age_ms(health.observed_at, now),
      freshness: freshness(health.state),
      partial: not health.complete?,
      reasons: Enum.reject([health.failure], &is_nil/1)
    }
  end

  # Only healthy or stale stores get this far; anything else failed closed.
  defp state(:healthy), do: :available
  defp state(:stale), do: :stale
  defp freshness(:healthy), do: :current
  defp freshness(:stale), do: :stale
  defp age_ms(%DateTime{} = observed_at, now), do: max(DateTime.diff(now, observed_at, :millisecond), 0)
  defp age_ms(_observed_at, _now), do: nil
end
