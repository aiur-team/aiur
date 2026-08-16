defmodule Aiur.RecentMerge do
  @moduledoc """
  Validated, bounded repository-merge fact used by the Executor control
  center.

  A merge can be backfilled from GitHub's bounded Events API window,
  observed live by the current BEAM run, or both. `observed_run_id` means
  only that the run saw the live GitHub event; it never claims that the run,
  an Aiur agent, or a ticket caused the merge. Ticket linkage is derived only
  from a canonical `aiur/<number>[-slug]` head branch.
  """

  alias Aiur.{SecretRedactor, TicketBranch}

  @schema_version 1
  @repository_max 200
  @title_max 200
  @summary_max 500
  @ref_max 500
  @identity_max 200

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          repository: String.t(),
          number: pos_integer(),
          title: String.t() | nil,
          summary: String.t() | nil,
          url: String.t(),
          head_ref: String.t() | nil,
          head_sha: String.t() | nil,
          merge_commit_sha: String.t() | nil,
          ticket_id: String.t() | nil,
          merged_by: String.t() | nil,
          merged_at: DateTime.t(),
          source_event_id: String.t() | nil,
          observation_source: :github_events,
          backfilled?: boolean(),
          live_observed?: boolean(),
          observed_run_id: String.t() | nil,
          first_observed_at: DateTime.t(),
          last_observed_at: DateTime.t(),
          content_hash: String.t()
        }

  @enforce_keys [
    :id,
    :repository,
    :number,
    :url,
    :merged_at,
    :observation_source,
    :backfilled?,
    :live_observed?,
    :first_observed_at,
    :last_observed_at,
    :content_hash
  ]
  defstruct @enforce_keys ++
              [
                schema_version: @schema_version,
                title: nil,
                summary: nil,
                head_ref: nil,
                head_sha: nil,
                merge_commit_sha: nil,
                ticket_id: nil,
                merged_by: nil,
                source_event_id: nil,
                observed_run_id: nil
              ]

  @doc "Normalizes one merged PullRequestEvent, or returns `:not_merge`."
  @spec from_github_event(map(), keyword()) :: {:ok, t()} | {:error, term()} | :not_merge
  def from_github_event(event, opts \\ [])

  def from_github_event(
        %{"type" => "PullRequestEvent", "payload" => %{"action" => action, "pull_request" => pull}} = event,
        opts
      )
      when is_map(pull) do
    if merged_pull_request_event?(action, Map.get(pull, "merged")) do
      normalize_github_merge(event, pull, opts)
    else
      :not_merge
    end
  end

  def from_github_event(_event, _opts), do: :not_merge

  @doc """
  Returns same-repository issue identifiers named by GitHub closing keywords in
  a merged pull request body.

  Detection is deliberately no wider than GitHub's documented rule, and in two
  places it is deliberately narrower. A false positive here force-closes a
  ticket the pull request never closed, so a missed reference (the ticket
  simply stays open) is the cheaper error.

  Recognised: a documented keyword — `close`/`closes`/`closed`,
  `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved` — immediately
  followed by its own reference, either `#123` or `owner/repo#123`. Each
  reference needs its own keyword: `Closes #1, #2` names only `#1`, exactly as
  GitHub treats it.

  Ignored: references inside fenced code blocks, inline code spans and
  blockquotes, which GitHub also ignores; and — narrower than GitHub —
  keywords buried mid-sentence, so prose such as `See also closed #55 last
  week` names nothing. A keyword is honoured only where it opens a line, a
  list item, or a clause after `,`, `;` or `and`.

  Cross-repository references are parsed but only same-repository ones are
  returned, since this reconciles tickets in the merge's own repository.

  This remains derived rather than persisted so existing merge-audit records
  retain their original content hashes.
  """
  @spec closing_issue_identifiers(t()) :: [String.t()]
  def closing_issue_identifiers(%__MODULE__{summary: summary, repository: repository}) when is_binary(summary) do
    summary
    |> closing_references_from_text()
    |> Enum.filter(fn {reference_repository, _number} ->
      reference_repository == nil or same_repository?(reference_repository, repository)
    end)
    |> Enum.map(fn {_repository, number} -> number end)
    |> Enum.uniq()
  end

  def closing_issue_identifiers(%__MODULE__{}), do: []

  defp normalize_github_merge(event, pull, opts) do
    live? = Keyword.get(opts, :live?, false) == true
    now = Keyword.get(opts, :now, DateTime.utc_now())
    repository = get_in(event, ["repo", "name"]) || Keyword.get(opts, :repo)

    with {:ok, repository} <- normalize_repository(repository),
         {:ok, number} <- positive_integer(Map.get(pull, "number"), :number),
         {:ok, url} <- normalize_url(Map.get(pull, "html_url"), repository, number),
         {:ok, title} <- optional_text(Map.get(pull, "title"), @title_max, :title),
         {:ok, summary} <- normalized_summary(Map.get(pull, "body")),
         {:ok, head_ref} <- optional_text(get_in(pull, ["head", "ref"]), @ref_max, :head_ref),
         {:ok, head_sha} <- optional_text(get_in(pull, ["head", "sha"]), @identity_max, :head_sha),
         {:ok, merge_sha} <-
           optional_text(Map.get(pull, "merge_commit_sha"), @identity_max, :merge_commit_sha),
         {:ok, merged_by} <-
           optional_text(get_in(pull, ["merged_by", "login"]), @identity_max, :merged_by),
         {:ok, source_event_id} <-
           optional_text(Map.get(event, "id"), @identity_max, :source_event_id),
         {:ok, merged_at} <- timestamp(Map.get(pull, "merged_at") || Map.get(event, "created_at"), :merged_at),
         {:ok, observed_at} <- datetime(now, :observed_at),
         {:ok, observed_run_id} <- observed_run_id(live?, Keyword.get(opts, :run_id)) do
      %__MODULE__{
        id: "#{repository}##{number}",
        repository: repository,
        number: number,
        title: title,
        summary: summary,
        url: url,
        head_ref: head_ref,
        head_sha: head_sha,
        merge_commit_sha: merge_sha,
        ticket_id: TicketBranch.ticket_id(head_ref),
        merged_by: merged_by,
        merged_at: merged_at,
        source_event_id: source_event_id,
        observation_source: :github_events,
        backfilled?: not live?,
        live_observed?: live?,
        observed_run_id: observed_run_id,
        first_observed_at: observed_at,
        last_observed_at: observed_at,
        content_hash: ""
      }
      |> with_content_hash()
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, {:recent_merge_invalid, reason}}
    end
  end

  @doc "Merges newly learned provenance/fields into a stored snapshot."
  @spec enrich(t(), t()) :: {:accepted, t()} | {:duplicate, t()}
  def enrich(%__MODULE__{id: id} = existing, %__MODULE__{id: id} = incoming) do
    candidate =
      %__MODULE__{
        existing
        | title: prefer(incoming.title, existing.title),
          summary: prefer(incoming.summary, existing.summary),
          head_ref: prefer(incoming.head_ref, existing.head_ref),
          head_sha: prefer(incoming.head_sha, existing.head_sha),
          merge_commit_sha: prefer(incoming.merge_commit_sha, existing.merge_commit_sha),
          ticket_id: prefer(incoming.ticket_id, existing.ticket_id),
          merged_by: prefer(incoming.merged_by, existing.merged_by),
          source_event_id: prefer(existing.source_event_id, incoming.source_event_id),
          backfilled?: existing.backfilled? or incoming.backfilled?,
          live_observed?: existing.live_observed? or incoming.live_observed?,
          observed_run_id: prefer(incoming.observed_run_id, existing.observed_run_id),
          last_observed_at: incoming.last_observed_at
      }
      |> with_content_hash()

    if comparable(candidate) == comparable(existing) do
      {:duplicate, existing}
    else
      {:accepted, candidate}
    end
  end

  @doc "JSON-safe full snapshot stored as one append-only audit record."
  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = merge) do
    %{
      "schema_version" => merge.schema_version,
      "id" => merge.id,
      "repository" => merge.repository,
      "number" => merge.number,
      "title" => merge.title,
      "summary" => merge.summary,
      "url" => merge.url,
      "head_ref" => merge.head_ref,
      "head_sha" => merge.head_sha,
      "merge_commit_sha" => merge.merge_commit_sha,
      "ticket_id" => merge.ticket_id,
      "merged_by" => merge.merged_by,
      "merged_at" => DateTime.to_iso8601(merge.merged_at),
      "source_event_id" => merge.source_event_id,
      "observation_source" => Atom.to_string(merge.observation_source),
      "backfilled" => merge.backfilled?,
      "live_observed" => merge.live_observed?,
      "observed_run_id" => merge.observed_run_id,
      "first_observed_at" => DateTime.to_iso8601(merge.first_observed_at),
      "last_observed_at" => DateTime.to_iso8601(merge.last_observed_at),
      "content_hash" => merge.content_hash
    }
  end

  @doc "Decodes and validates a persisted full snapshot."
  @spec decode_record(map()) :: {:ok, t()} | {:error, term()}
  def decode_record(raw) when is_map(raw) do
    with {:ok, @schema_version} <- exact(Map.get(raw, "schema_version"), @schema_version, :schema_version),
         {:ok, repository} <- normalize_repository(Map.get(raw, "repository")),
         {:ok, number} <- positive_integer(Map.get(raw, "number"), :number),
         {:ok, id} <- exact(Map.get(raw, "id"), "#{repository}##{number}", :id),
         {:ok, url} <- normalize_url(Map.get(raw, "url"), repository, number),
         {:ok, title} <- optional_text(Map.get(raw, "title"), @title_max, :title),
         {:ok, summary} <- optional_text(Map.get(raw, "summary"), @summary_max, :summary),
         {:ok, head_ref} <- optional_text(Map.get(raw, "head_ref"), @ref_max, :head_ref),
         {:ok, head_sha} <- optional_text(Map.get(raw, "head_sha"), @identity_max, :head_sha),
         {:ok, merge_sha} <-
           optional_text(Map.get(raw, "merge_commit_sha"), @identity_max, :merge_commit_sha),
         {:ok, ticket_id} <- optional_text(Map.get(raw, "ticket_id"), @identity_max, :ticket_id),
         {:ok, derived_ticket} <- exact(ticket_id, TicketBranch.ticket_id(head_ref), :ticket_id),
         {:ok, merged_by} <- optional_text(Map.get(raw, "merged_by"), @identity_max, :merged_by),
         {:ok, source_event_id} <-
           optional_text(Map.get(raw, "source_event_id"), @identity_max, :source_event_id),
         {:ok, merged_at} <- timestamp(Map.get(raw, "merged_at"), :merged_at),
         {:ok, "github_events"} <-
           exact(Map.get(raw, "observation_source"), "github_events", :observation_source),
         {:ok, backfilled?} <- boolean(Map.get(raw, "backfilled"), :backfilled),
         {:ok, live_observed?} <- boolean(Map.get(raw, "live_observed"), :live_observed),
         {:ok, observed_run_id} <-
           replay_run_id(live_observed?, Map.get(raw, "observed_run_id")),
         {:ok, first_observed_at} <- timestamp(Map.get(raw, "first_observed_at"), :first_observed_at),
         {:ok, last_observed_at} <- timestamp(Map.get(raw, "last_observed_at"), :last_observed_at),
         :ok <- ordered_observations(first_observed_at, last_observed_at),
         {:ok, content_hash} <- required_text(Map.get(raw, "content_hash"), @identity_max, :content_hash) do
      merge = %__MODULE__{
        id: id,
        repository: repository,
        number: number,
        title: title,
        summary: summary,
        url: url,
        head_ref: head_ref,
        head_sha: head_sha,
        merge_commit_sha: merge_sha,
        ticket_id: derived_ticket,
        merged_by: merged_by,
        merged_at: merged_at,
        source_event_id: source_event_id,
        observation_source: :github_events,
        backfilled?: backfilled?,
        live_observed?: live_observed?,
        observed_run_id: observed_run_id,
        first_observed_at: first_observed_at,
        last_observed_at: last_observed_at,
        content_hash: content_hash
      }

      if with_content_hash(merge).content_hash == content_hash do
        {:ok, merge}
      else
        {:error, :content_hash_mismatch}
      end
    end
  end

  def decode_record(_raw), do: {:error, :not_a_map}

  defp with_content_hash(merge) do
    hash =
      merge
      |> Map.from_struct()
      |> Map.delete(:content_hash)
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{merge | content_hash: hash}
  end

  defp comparable(merge) do
    merge
    |> Map.from_struct()
    |> Map.drop([:last_observed_at, :content_hash])
  end

  defp prefer(nil, fallback), do: fallback
  defp prefer(value, _fallback), do: value

  defp normalize_repository(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) <= @repository_max and
         Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value) do
      {:ok, value}
    else
      {:error, {:repository, :invalid}}
    end
  end

  defp normalize_repository(_value), do: {:error, {:repository, :invalid}}

  defp normalize_url(nil, repository, number), do: {:ok, canonical_url(repository, number)}

  defp normalize_url(value, repository, number) when is_binary(value) do
    uri = URI.parse(value)
    expected = canonical_url(repository, number)

    if value == expected and uri.scheme == "https" and uri.host == "github.com" and
         uri.userinfo in [nil, ""] and uri.query == nil and uri.fragment == nil do
      {:ok, value}
    else
      {:error, {:url, :unsafe}}
    end
  end

  defp normalize_url(_value, _repository, _number), do: {:error, {:url, :unsafe}}

  defp canonical_url(repository, number), do: "https://github.com/#{repository}/pull/#{number}"

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, field), do: {:error, {field, :invalid}}

  defp optional_text(nil, _max, _field), do: {:ok, nil}
  defp optional_text("", _max, _field), do: {:ok, nil}

  defp optional_text(value, max, field) when is_binary(value) do
    value = String.trim(value)

    if unsafe_control_chars?(value) do
      {:error, {field, :unsafe_characters}}
    else
      {:ok, value |> SecretRedactor.redact() |> truncate(max) |> empty_to_nil()}
    end
  end

  defp optional_text(_value, _max, field), do: {:error, {field, :invalid_type}}

  defp normalized_summary(body) do
    with {:ok, summary} <- optional_text(body, @summary_max, :summary) do
      {:ok, preserve_closing_references(summary, closing_references_from_text(body))}
    end
  end

  defp preserve_closing_references(summary, []), do: summary

  defp preserve_closing_references(summary, references) when is_binary(summary) do
    missing = Enum.reject(references, &(&1 in closing_references_from_text(summary)))

    if missing == [] do
      summary
    else
      suffix = closing_reference_suffix(missing)
      String.slice(summary, 0, @summary_max - String.length(suffix)) <> suffix
    end
  end

  defp preserve_closing_references(summary, _references), do: summary

  # Each retained reference gets its own keyword on its own line: a
  # comma-chained list would silently lose every reference after the first
  # when the summary is read back.
  defp closing_reference_suffix(references) do
    Enum.reduce(references, "", fn reference, suffix ->
      candidate = suffix <> "\nCloses " <> reference_text(reference)

      if String.length(candidate) <= @summary_max, do: candidate, else: suffix
    end)
  end

  defp reference_text({nil, number}), do: "##{number}"
  defp reference_text({repository, number}), do: "#{repository}##{number}"

  # A keyword counts only where it opens a line, a list item, or a clause
  # introduced by `,`, `;` or `and`, and it must be followed by its own
  # reference. See `closing_issue_identifiers/1` for why this is narrower than
  # GitHub in prose position.
  @closing_reference_regex ~r/
    (?:^[ \t]*(?:[-*+][ \t]+|\d+[.)][ \t]+)?|[,;][ \t]*|\band[ \t]+)
    \**
    (?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)
    \**
    (?::[ \t]*|[ \t]+)
    (?<repository>[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+)?
    \#(?<number>\d+)\b
  /imx

  defp closing_references_from_text(text) when is_binary(text) do
    text
    |> quotable_text()
    |> then(&Regex.scan(@closing_reference_regex, &1, capture: [:repository, :number]))
    |> Enum.map(fn [repository, number] -> {empty_to_nil(repository), number} end)
    |> Enum.filter(fn {_repository, number} -> String.to_integer(number) > 0 end)
    |> Enum.map(fn {repository, number} ->
      {repository, number |> String.to_integer() |> Integer.to_string()}
    end)
    |> Enum.uniq()
  end

  defp closing_references_from_text(_text), do: []

  # Drops the regions GitHub itself does not read closing keywords from:
  # fenced code blocks, inline code spans and blockquotes.
  defp quotable_text(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({[], nil}, &collect_quotable_line/2)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp collect_quotable_line(line, {kept, nil}) do
    case fence_marker(line) do
      nil -> {maybe_keep_line(line, kept), nil}
      marker -> {kept, marker}
    end
  end

  defp collect_quotable_line(line, {kept, open_marker}) do
    case fence_marker(line) do
      marker when is_binary(marker) and byte_size(marker) >= byte_size(open_marker) ->
        if String.first(marker) == String.first(open_marker), do: {kept, nil}, else: {kept, open_marker}

      _ ->
        {kept, open_marker}
    end
  end

  defp maybe_keep_line(line, kept) do
    if blockquote_line?(line), do: kept, else: [strip_inline_code(line) | kept]
  end

  defp fence_marker(line) do
    case Regex.run(~r/^[ \t]{0,3}(`{3,}|~{3,})/, line) do
      [_match, marker] -> marker
      nil -> nil
    end
  end

  defp blockquote_line?(line), do: Regex.match?(~r/^[ \t]{0,3}>/, line)

  defp strip_inline_code(line), do: String.replace(line, ~r/`[^`]*`/, " ")

  defp same_repository?(reference_repository, repository) when is_binary(repository) do
    String.downcase(reference_repository) == String.downcase(repository)
  end

  defp same_repository?(_reference_repository, _repository), do: false

  defp required_text(value, max, field) do
    case optional_text(value, max, field) do
      {:ok, nil} -> {:error, {field, :missing}}
      result -> result
    end
  end

  defp truncate(value, max) do
    if String.length(value) > max do
      String.slice(value, 0, max - 1) <> "…"
    else
      value
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {field, :invalid_timestamp}}
    end
  end

  defp timestamp(_value, field), do: {:error, {field, :missing_or_invalid}}

  defp datetime(%DateTime{} = value, _field), do: {:ok, value}
  defp datetime(_value, field), do: {:error, {field, :invalid_timestamp}}

  defp observed_run_id(false, _run_id), do: {:ok, nil}
  defp observed_run_id(true, run_id), do: required_text(run_id, @identity_max, :observed_run_id)

  defp merged_pull_request_event?("merged", _merged), do: true
  defp merged_pull_request_event?("closed", true), do: true
  defp merged_pull_request_event?(_action, _merged), do: false

  defp replay_run_id(true, run_id), do: required_text(run_id, @identity_max, :observed_run_id)

  defp replay_run_id(false, nil), do: {:ok, nil}
  defp replay_run_id(false, _run_id), do: {:error, {:observed_run_id, :without_live_observation}}

  defp boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, field), do: {:error, {field, :invalid_type}}

  defp exact(value, value, _field), do: {:ok, value}
  defp exact(_value, _expected, field), do: {:error, {field, :invalid}}

  defp ordered_observations(first, last) do
    if DateTime.compare(first, last) in [:lt, :eq], do: :ok, else: {:error, {:observed_at, :out_of_order}}
  end
end
