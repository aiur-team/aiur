defmodule Aiur.DecisionValidation do
  @moduledoc """
  Normalizes an untrusted `decision.requested` payload into an
  `Aiur.Decision` struct, or returns the first validation failure found
  as a structured, matchable error.

  Trusted runtime context (ticket, source agent/session identity, safe
  artifact roots, acceptance time) is injected via `opts` — never
  accepted from the raw payload, so an agent-provided value cannot
  impersonate another ticket or session, or forge audit order. Any
  source-reported timestamp is preserved separately as provenance and
  never controls the canonical `created_at`.

  `version` is always normalized as `1` and `content_hash` covers only
  the meaningful request content (question, options, context,
  artifacts, authority, urgency, blocking, reversibility, kind,
  recommendation, consequence_of_delay, and trusted legacy-attention
  provenance when present) — never source/decision_id/version/created_at.
  Optional runtime provenance is instead protected by the typed Decision event
  envelope, preserving the request hash shape for rollback-compatible reads.
  `Aiur.DecisionStore` (which owns
  replay/version/dedup state) decides whether a request is a fresh
  Decision, an accepted enrichment, or a duplicate.
  """

  alias Aiur.{Config, Decision, DecisionArtifact, DecisionProvenance, SecretRedactor}

  @question_max 2000
  @short_summary_max 500
  @long_context_max 20_000
  @consequence_max 2000
  @kind_max 100
  @identity_max 200
  @ticket_title_max 500
  @ticket_url_max 2048
  @option_label_max 200
  @option_text_max 2000
  @options_max 20
  @artifacts_max 20
  @artifact_value_max 4096
  @legacy_attention_slug_max 64
  @legacy_attention_topic_max 500

  @default_authority :human_required
  @default_urgency :normal
  @default_reversibility :irreversible

  @type error :: {atom(), atom()}

  @doc """
  Normalizes `payload` into an `Aiur.Decision`. `opts`:

    * `:ticket` (required) — trusted `%{identifier:, title:, url:}`.
    * `:source` — trusted `%{agent_id:, session_id:, event_id:}`.
    * `:provenance` — optional trusted runtime/session facts, captured at the
      supplied acceptance time and never read from the payload.
    * `:now` — acceptance time, defaults to `DateTime.utc_now/0`.
    * `:safe_roots` — allowed local-artifact roots, defaults to the
      configured workspace root and log root.
  """
  @spec normalize(map(), keyword()) :: {:ok, Decision.t()} | {:error, {:decision_invalid, error()}}
  def normalize(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    ticket = Keyword.fetch!(opts, :ticket)
    source = Keyword.get(opts, :source, %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())
    provenance = Keyword.get(opts, :provenance)
    safe_roots = Keyword.get(opts, :safe_roots, default_safe_roots())

    with {:ok, normalized_ticket} <- normalize_ticket(ticket),
         {:ok, legacy_attention} <-
           normalize_legacy_attention(Keyword.get(opts, :legacy_attention), normalized_ticket),
         {:ok, provenance} <- DecisionProvenance.normalize(provenance, now),
         {:ok, question} <- fetch_required_string(payload, :question, 1, @question_max, :question),
         {:ok, authority} <-
           fetch_enum_with_default(payload, :authority, Decision.authorities(), @default_authority, :authority),
         {:ok, urgency} <-
           fetch_enum_with_default(payload, :urgency, Decision.urgencies(), @default_urgency, :urgency),
         {:ok, blocking} <- fetch_required_boolean(payload, :blocking, :blocking),
         {:ok, reversibility} <-
           fetch_enum_with_default(
             payload,
             :reversibility,
             Decision.reversibilities(),
             @default_reversibility,
             :reversibility
           ),
         {:ok, kind} <- fetch_optional_string(payload, :kind, @kind_max, :kind),
         {:ok, context} <- fetch_context(payload),
         {:ok, options} <- fetch_options(payload),
         {:ok, recommendation} <- fetch_recommendation(payload, options),
         {:ok, consequence_of_delay} <-
           fetch_optional_string(payload, :consequence_of_delay, @consequence_max, :consequence_of_delay),
         {:ok, artifacts} <- fetch_artifacts(payload, safe_roots),
         {:ok, source_id} <- fetch_optional_string(payload, :source_id, @identity_max, :source_id),
         {:ok, source_created_at} <- fetch_optional_timestamp(payload, :created_at, :source_created_at) do
      content =
        %{
          question: question,
          authority: authority,
          urgency: urgency,
          blocking: blocking,
          reversibility: reversibility,
          kind: kind,
          context: context,
          options: options,
          recommendation: recommendation,
          consequence_of_delay: consequence_of_delay,
          artifacts: artifacts
        }
        |> maybe_put_legacy_attention(legacy_attention)

      decision = %Decision{
        decision_id: decision_id(ticket, source_id),
        source_id: source_id,
        version: 1,
        ticket: normalized_ticket,
        source: normalize_source(source),
        kind: kind,
        authority: authority,
        urgency: urgency,
        blocking: blocking,
        reversibility: reversibility,
        question: question,
        context: context,
        options: options,
        recommendation: recommendation,
        consequence_of_delay: consequence_of_delay,
        artifacts: artifacts,
        created_at: now,
        source_created_at: source_created_at,
        legacy_attention: legacy_attention,
        provenance: provenance,
        content_hash: content_hash(content)
      }

      {:ok, decision}
    else
      {:error, error} -> {:error, {:decision_invalid, error}}
    end
  end

  @doc "Hash of only the meaningful request content, used for dedup/idempotency comparison."
  @spec content_hash(map()) :: String.t()
  def content_hash(content) do
    content
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp get(payload, key) when is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp fetch_required_string(payload, key, min, max, field) do
    case get(payload, key) do
      value when is_binary(value) -> bound_string(value, min, max, field)
      nil -> {:error, {field, :missing}}
      _other -> {:error, {field, :invalid_type}}
    end
  end

  defp fetch_optional_string(payload, key, max, field) do
    case get(payload, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> bound_string(value, 0, max, field)
      _other -> {:error, {field, :invalid_type}}
    end
  end

  defp bound_string(value, min, max, field) do
    trimmed = String.trim(value)

    cond do
      String.length(trimmed) < min -> {:error, {field, :too_short}}
      String.length(trimmed) > max -> {:error, {field, :too_long}}
      unsafe_control_chars?(trimmed) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp fetch_required_boolean(payload, key, field) do
    case get(payload, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:error, {field, :missing}}
      _other -> {:error, {field, :invalid_type}}
    end
  end

  defp fetch_enum_with_default(payload, key, allowed, default, field) do
    case get(payload, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> to_allowed_atom(value, allowed, field)
      value when is_atom(value) -> if value in allowed, do: {:ok, value}, else: {:error, {field, :invalid_enum}}
      _other -> {:error, {field, :invalid_type}}
    end
  end

  defp to_allowed_atom(value, allowed, field) do
    atom_value = String.to_existing_atom(value)
    if atom_value in allowed, do: {:ok, atom_value}, else: {:error, {field, :invalid_enum}}
  rescue
    ArgumentError -> {:error, {field, :invalid_enum}}
  end

  defp fetch_context(payload) do
    case get(payload, :context) do
      nil ->
        {:ok, %{short_summary: nil, long_context_markdown: nil}}

      context when is_map(context) ->
        with {:ok, short_summary} <-
               fetch_optional_string(context, :short_summary, @short_summary_max, :context_short_summary),
             {:ok, long_context_markdown} <-
               fetch_optional_string(
                 context,
                 :long_context_markdown,
                 @long_context_max,
                 :context_long_context_markdown
               ) do
          {:ok, %{short_summary: short_summary, long_context_markdown: long_context_markdown}}
        end

      _other ->
        {:error, {:context, :invalid_type}}
    end
  end

  defp fetch_options(payload) do
    case get(payload, :options) do
      nil ->
        {:ok, []}

      list when is_list(list) and length(list) > @options_max ->
        {:error, {:options, :too_many}}

      list when is_list(list) ->
        normalize_options(list, [])

      _other ->
        {:error, {:options, :invalid_type}}
    end
  end

  defp normalize_options([], acc) do
    options = Enum.reverse(acc)
    ids = Enum.map(options, & &1.id)

    if length(ids) == length(Enum.uniq(ids)) do
      {:ok, options}
    else
      {:error, {:options, :duplicate_id}}
    end
  end

  defp normalize_options([raw | rest], acc) when is_map(raw) do
    with {:ok, id} <- fetch_required_string(raw, :id, 1, @identity_max, :option_id),
         {:ok, label} <- fetch_required_string(raw, :label, 1, @option_label_max, :option_label),
         {:ok, description} <- fetch_optional_string(raw, :description, @option_text_max, :option_description),
         {:ok, benefits} <- fetch_optional_string(raw, :benefits, @option_text_max, :option_benefits),
         {:ok, drawbacks} <- fetch_optional_string(raw, :drawbacks, @option_text_max, :option_drawbacks),
         {:ok, risk} <- fetch_optional_string(raw, :risk, @option_text_max, :option_risk) do
      option = %{id: id, label: label, description: description, benefits: benefits, drawbacks: drawbacks, risk: risk}
      normalize_options(rest, [option | acc])
    end
  end

  defp normalize_options([_invalid | _rest], _acc), do: {:error, {:options, :invalid_type}}

  defp fetch_recommendation(payload, options) do
    case get(payload, :recommendation) do
      nil ->
        {:ok, nil}

      rec when is_map(rec) ->
        with {:ok, option_id} <- fetch_required_string(rec, :option_id, 1, @identity_max, :recommendation_option_id),
             {:ok, reason} <- fetch_optional_string(rec, :reason, @option_text_max, :recommendation_reason) do
          build_recommendation(option_id, reason, options)
        end

      _other ->
        {:error, {:recommendation, :invalid_type}}
    end
  end

  defp build_recommendation(option_id, reason, options) do
    if Enum.any?(options, &(&1.id == option_id)) do
      {:ok, %{option_id: option_id, reason: reason}}
    else
      {:error, {:recommendation, :dangling_option_id}}
    end
  end

  defp fetch_artifacts(payload, safe_roots) do
    case get(payload, :artifacts) do
      nil ->
        {:ok, []}

      list when is_list(list) and length(list) > @artifacts_max ->
        {:error, {:artifacts, :too_many}}

      list when is_list(list) ->
        normalize_artifacts(list, safe_roots, [])

      _other ->
        {:error, {:artifacts, :invalid_type}}
    end
  end

  defp normalize_artifacts([], _safe_roots, acc), do: {:ok, Enum.reverse(acc)}

  # Ingress shape (a fresh, unvalidated agent payload) is a raw path/URL
  # string. Replay feeds back the *persisted* shape instead — the
  # `%{"kind" =>, "value" =>}` map `Aiur.DecisionProjection.to_json_safe/1`
  # writes — so both are accepted here, re-running the extracted value
  # through the same validator either way (full re-validation on replay,
  # not a trust-the-shape shortcut).
  defp normalize_artifacts([raw | rest], safe_roots, acc) when is_binary(raw) do
    validate_artifact(raw, rest, safe_roots, acc)
  end

  defp normalize_artifacts([%{"value" => value} | rest], safe_roots, acc) when is_binary(value) do
    validate_artifact(value, rest, safe_roots, acc)
  end

  defp normalize_artifacts([_invalid | _rest], _safe_roots, _acc), do: {:error, {:artifacts, :invalid_type}}

  defp validate_artifact(value, _rest, _safe_roots, _acc)
       when byte_size(value) > @artifact_value_max do
    {:error, {:artifacts, :too_long}}
  end

  defp validate_artifact(value, rest, safe_roots, acc) do
    case DecisionArtifact.validate(value, safe_roots) do
      {:ok, artifact} -> normalize_artifacts(rest, safe_roots, [artifact | acc])
      {:error, reason} -> {:error, {:artifacts, reason}}
    end
  end

  defp fetch_optional_timestamp(payload, key, field) do
    case get(payload, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, {field, :invalid_timestamp}}
        end

      _other ->
        {:error, {field, :invalid_type}}
    end
  end

  defp normalize_legacy_attention(nil, _ticket), do: {:ok, nil}

  defp normalize_legacy_attention(legacy_attention, ticket) when is_map(legacy_attention) do
    with {:ok, slug} <-
           fetch_required_string(
             legacy_attention,
             :slug,
             1,
             @legacy_attention_slug_max,
             :legacy_attention_slug
           ),
         :ok <- validate_legacy_attention_slug(slug),
         {:ok, topic} <-
           fetch_required_string(
             legacy_attention,
             :topic,
             1,
             @legacy_attention_topic_max,
             :legacy_attention_topic
           ),
         :ok <- validate_legacy_attention_topic(topic, ticket.identifier, slug) do
      {:ok, %{slug: slug, topic: topic}}
    end
  end

  defp normalize_legacy_attention(_legacy_attention, _ticket) do
    {:error, {:legacy_attention, :invalid_type}}
  end

  defp validate_legacy_attention_slug(slug) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,63}\z/, slug) do
      :ok
    else
      {:error, {:legacy_attention_slug, :invalid_format}}
    end
  end

  defp validate_legacy_attention_topic(topic, ticket_identifier, slug) do
    if topic == "ticket.#{ticket_identifier}.agent.attention.#{slug}" do
      :ok
    else
      {:error, {:legacy_attention_topic, :mismatch}}
    end
  end

  # The pre-OCC-2 hash shape did not contain this key at all. Preserve that
  # byte-for-byte shape when provenance is absent so existing audit records
  # continue to pass replay integrity checks after upgrading.
  defp maybe_put_legacy_attention(content, nil), do: content
  defp maybe_put_legacy_attention(content, legacy_attention), do: Map.put(content, :legacy_attention, legacy_attention)

  defp normalize_ticket(ticket) when is_map(ticket) do
    with {:ok, identifier} <- normalize_ticket_identifier(get(ticket, :identifier)),
         {:ok, title} <- fetch_optional_string(ticket, :title, @ticket_title_max, :ticket_title),
         {:ok, url} <- fetch_optional_string(ticket, :url, @ticket_url_max, :ticket_url) do
      {:ok, %{identifier: identifier, title: title, url: url}}
    end
  end

  defp normalize_ticket(_ticket), do: {:error, {:ticket, :invalid_type}}

  defp normalize_ticket_identifier(nil), do: {:error, {:ticket_identifier, :missing}}

  defp normalize_ticket_identifier(identifier) do
    identifier
    |> to_string()
    |> bound_string(1, @identity_max, :ticket_identifier)
  end

  defp normalize_source(source) do
    %{
      agent_id: get(source, :agent_id),
      session_id: get(source, :session_id),
      event_id: get(source, :event_id)
    }
  end

  # Deterministic from trusted ticket scope + a stable agent-proposed source
  # id, so a retried request from the same conversation resolves to the same
  # canonical identity. Without a source id, mints a fresh (non-replayable)
  # component — the caller is expected to supply a stable one for dedup to
  # apply across retries.
  defp decision_id(ticket, source_id) do
    ticket_identifier = get(ticket, :identifier)
    material = "#{ticket_identifier}::#{source_id || unique_component()}"

    digest =
      material
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    "dec_" <> digest
  end

  defp unique_component do
    8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp default_safe_roots do
    case Config.settings() do
      {:ok, settings} -> [Config.Paths.log_root_dir(), settings.workspace.root]
      _other -> [Config.Paths.log_root_dir()]
    end
  end
end
