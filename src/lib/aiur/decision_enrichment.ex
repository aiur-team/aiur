defmodule Aiur.DecisionEnrichment do
  @moduledoc """
  Pure normalization for a supervising-agent enrichment of one Decision.

  The result is an append candidate with trusted actor/version correlation. It
  deliberately performs no persistence or publication; `Aiur.DecisionStore`
  remains the only writer once its lifecycle event seam accepts enrichment.
  """

  alias Aiur.{Decision, DecisionProjection, DecisionValidation}

  @supervisor_actor %{kind: :supervisor, id: "supervising-agent"}
  @allowed_fields ~w(artifacts consequence_of_delay context options recommendation)
  @forbidden_fields ~w(
    actor authority blocking content_hash created_at decision_id kind question
    reversibility schema_version source source_created_at source_id ticket urgency version
  )
  @context_fields ~w(long_context_markdown short_summary)
  @option_fields ~w(benefits description drawbacks id label risk)
  @recommendation_fields ~w(option_id reason)
  @artifact_fields ~w(kind value)

  @type normalized :: %{
          actor: %{kind: :supervisor, id: String.t()},
          changed: boolean(),
          decision: Decision.t(),
          expected_version: pos_integer()
        }

  @doc "Normalizes a narrow patch against the current canonical Decision."
  @spec normalize(Decision.t(), map(), keyword()) :: {:ok, normalized()} | {:error, term()}
  def normalize(%Decision{} = current, patch, opts) when is_map(patch) and is_list(opts) do
    with :ok <- require_nonempty_patch(patch),
         {:ok, expected_version} <- expected_version(opts, current.version),
         {:ok, actor} <- trusted_actor(opts),
         {:ok, now} <- acceptance_time(opts),
         {:ok, normalized_patch} <- normalize_patch(patch),
         merged_payload <- merge_patch(current, normalized_patch),
         {:ok, normalized} <- DecisionValidation.normalize(merged_payload, validation_opts(current, now, opts)) do
      decision = %{
        current
        | version: current.version + 1,
          context: normalized.context,
          options: normalized.options,
          recommendation: normalized.recommendation,
          consequence_of_delay: normalized.consequence_of_delay,
          artifacts: normalized.artifacts,
          content_hash: normalized.content_hash
      }

      {:ok,
       %{
         actor: actor,
         changed: decision.content_hash != current.content_hash,
         decision: decision,
         expected_version: expected_version
       }}
    else
      {:error, {:decision_invalid, _reason}} = error -> error
      {:error, reason} -> {:error, {:enrichment_invalid, reason}}
    end
  end

  def normalize(%Decision{}, _patch, _opts), do: {:error, {:enrichment_invalid, :not_a_map}}

  defp require_nonempty_patch(patch) when map_size(patch) == 0, do: {:error, :empty_patch}
  defp require_nonempty_patch(_patch), do: :ok

  defp expected_version(opts, current_version) do
    case Keyword.get(opts, :expected_version) do
      version when is_integer(version) and version > 0 ->
        if version == current_version,
          do: {:ok, version},
          else: {:error, {:stale_version, version, current_version}}

      _invalid ->
        {:error, {:expected_version, :invalid}}
    end
  end

  defp trusted_actor(opts) do
    case Keyword.get(opts, :actor) do
      @supervisor_actor = actor -> {:ok, actor}
      _untrusted -> {:error, {:actor, :untrusted}}
    end
  end

  defp acceptance_time(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> {:ok, now}
      _invalid -> {:error, {:now, :invalid}}
    end
  end

  defp normalize_patch(patch) do
    with {:ok, normalized} <- normalize_keys(patch),
         :ok <- validate_top_level_fields(normalized),
         {:ok, normalized} <- normalize_optional_map(normalized, "context", :context, @context_fields),
         {:ok, normalized} <- normalize_optional_list_of_maps(normalized, "options", :option, @option_fields),
         {:ok, normalized} <-
           normalize_optional_map(normalized, "recommendation", :recommendation, @recommendation_fields),
         {:ok, normalized} <-
           normalize_optional_list_of_maps(normalized, "artifacts", :artifact, @artifact_fields) do
      {:ok, normalized}
    end
  end

  defp validate_top_level_fields(patch) do
    keys = Map.keys(patch)
    forbidden = keys |> Enum.filter(&(&1 in @forbidden_fields)) |> Enum.sort()

    unknown =
      keys
      |> Enum.reject(&(&1 in @allowed_fields or &1 in @forbidden_fields))
      |> Enum.sort()

    cond do
      forbidden != [] -> {:error, {:forbidden_fields, forbidden}}
      unknown != [] -> {:error, {:unknown_fields, :enrichment, unknown}}
      true -> :ok
    end
  end

  defp normalize_optional_map(patch, field, location, allowed_fields) do
    case Map.fetch(patch, field) do
      {:ok, value} when is_map(value) ->
        with {:ok, normalized} <- normalize_keys(value),
             :ok <- validate_nested_fields(normalized, location, allowed_fields) do
          {:ok, Map.put(patch, field, normalized)}
        end

      _missing_or_other ->
        {:ok, patch}
    end
  end

  defp normalize_optional_list_of_maps(patch, field, location, allowed_fields) do
    case Map.fetch(patch, field) do
      {:ok, values} when is_list(values) ->
        values
        |> Enum.reduce_while({:ok, []}, fn
          value, {:ok, acc} when is_map(value) ->
            with {:ok, normalized} <- normalize_keys(value),
                 :ok <- validate_nested_fields(normalized, location, allowed_fields) do
              {:cont, {:ok, [normalized | acc]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          value, {:ok, acc} ->
            {:cont, {:ok, [value | acc]}}
        end)
        |> case do
          {:ok, normalized} -> {:ok, Map.put(patch, field, Enum.reverse(normalized))}
          {:error, reason} -> {:error, reason}
        end

      _missing_or_other ->
        {:ok, patch}
    end
  end

  defp validate_nested_fields(map, location, allowed_fields) do
    case Enum.sort(Map.keys(map) -- allowed_fields) do
      [] -> :ok
      unknown -> {:error, {:unknown_fields, location, unknown}}
    end
  end

  defp normalize_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      case normalize_key(raw_key) do
        {:ok, key} ->
          if Map.has_key?(normalized, key) do
            {:halt, {:error, {:duplicate_fields, [key]}}}
          else
            {:cont, {:ok, Map.put(normalized, key, value)}}
          end

        :error ->
          {:halt, {:error, {:field, :invalid}}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error

  defp merge_patch(current, patch) do
    Enum.reduce(patch, DecisionProjection.to_request_payload(current), fn
      {"context", context}, payload when is_map(context) ->
        Map.update!(payload, "context", &Map.merge(&1, context))

      {field, value}, payload ->
        Map.put(payload, field, value)
    end)
  end

  defp validation_opts(current, now, opts) do
    [
      ticket: current.ticket,
      source: current.source,
      now: now,
      legacy_attention: current.legacy_attention
    ]
    |> maybe_put_safe_roots(opts)
  end

  defp maybe_put_safe_roots(validation_opts, opts) do
    if Keyword.has_key?(opts, :safe_roots) do
      Keyword.put(validation_opts, :safe_roots, Keyword.get(opts, :safe_roots))
    else
      validation_opts
    end
  end
end
