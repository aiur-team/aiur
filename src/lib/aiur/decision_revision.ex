defmodule Aiur.DecisionRevision do
  @moduledoc """
  Immutable, ordered correction to one active Decision action.

  Revision-specific optimistic correlation is validated before delegating the
  replacement answer to OCC-3's normalizer. The injected normalizer keeps this
  value object from copying answer bounds, option checks, actor validation, or
  redaction. `Aiur.DecisionStore` remains responsible for serializing the
  comparison and appending an accepted value.
  """

  alias Aiur.DecisionValidation

  @identity_max 256
  @follow_up_slug_prefix "decision-revision-"

  @type normalized_answer :: %{
          required(:action_id) => String.t(),
          required(:decision_id) => String.t(),
          required(:decision_version) => pos_integer(),
          required(:actor) => map(),
          required(:accepted_at) => DateTime.t(),
          required(:content_hash) => String.t(),
          required(:rationale) => String.t(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          decision_id: String.t(),
          decision_version: pos_integer(),
          sequence: pos_integer(),
          action_id: String.t(),
          prior_action_id: String.t(),
          answer: normalized_answer(),
          reason: String.t(),
          recorded_at: DateTime.t(),
          content_hash: String.t()
        }

  @enforce_keys [
    :decision_id,
    :decision_version,
    :sequence,
    :action_id,
    :prior_action_id,
    :answer,
    :reason,
    :recorded_at,
    :content_hash
  ]
  defstruct @enforce_keys

  @doc "Normalize revision correlation and compose an OCC-3 normalized answer."
  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, {:revision_invalid, term()}}
  def normalize(payload, opts) when is_map(payload) and is_list(opts) do
    with {:ok, context} <- normalize_context(opts),
         {:ok, expected_action_id} <- required_string(payload, :expected_action_id),
         :ok <- compare_action(expected_action_id, context.current_action_id),
         {:ok, expected_sequence} <- required_sequence(payload),
         :ok <- compare_sequence(expected_sequence, context.current_revision_sequence),
         {:ok, answer} <- normalize_answer(payload, opts, context.answer_normalizer),
         {:ok, answer} <- validate_answer(answer, context),
         :ok <- changed_action(answer.action_id, context.current_action_id),
         {:ok, reason} <- required_reason(answer) do
      {:ok, build(context, answer, reason)}
    else
      {:error, {:revision_invalid, _reason}} = error -> error
      {:error, reason} -> {:error, {:revision_invalid, reason}}
    end
  end

  @doc "Stable DecisionAttention slug for an un-applicable revision action."
  @spec follow_up_slug(t() | String.t()) :: String.t()
  def follow_up_slug(%__MODULE__{action_id: action_id}), do: follow_up_slug(action_id)

  def follow_up_slug(action_id) when is_binary(action_id) and action_id != "" do
    digest =
      action_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 20)

    @follow_up_slug_prefix <> digest
  end

  defp normalize_context(opts) do
    with {:ok, decision_id} <- context_string(opts, :decision_id),
         {:ok, decision_version} <- context_positive_integer(opts, :decision_version),
         {:ok, current_action_id} <- context_string(opts, :current_action_id),
         {:ok, current_revision_sequence} <- context_non_negative_integer(opts, :current_revision_sequence),
         {:ok, actor} <- context_map(opts, :actor),
         {:ok, now} <- context_datetime(opts, :now),
         {:ok, answer_normalizer} <- context_normalizer(opts) do
      {:ok,
       %{
         decision_id: decision_id,
         decision_version: decision_version,
         current_action_id: current_action_id,
         current_revision_sequence: current_revision_sequence,
         actor: actor,
         now: now,
         answer_normalizer: answer_normalizer
       }}
    end
  end

  defp normalize_answer(payload, opts, normalizer) do
    case normalizer.(payload, opts) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:answer_normalizer, :invalid_result}}
    end
  end

  defp validate_answer(
         %{
           action_id: action_id,
           decision_id: decision_id,
           decision_version: decision_version,
           actor: actor,
           accepted_at: accepted_at,
           content_hash: content_hash
         } = answer,
         context
       )
       when is_binary(action_id) and action_id != "" and is_binary(content_hash) and content_hash != "" do
    if decision_id == context.decision_id and decision_version == context.decision_version and
         actor == context.actor and accepted_at == context.now do
      {:ok, answer}
    else
      {:error, {:answer, :identity_mismatch}}
    end
  end

  defp validate_answer(_answer, _context), do: {:error, {:answer, :invalid}}

  defp required_reason(%{rationale: reason}) when is_binary(reason) and reason != "", do: {:ok, reason}
  defp required_reason(_answer), do: {:error, {:reason, :missing}}

  defp build(context, answer, reason) do
    sequence = context.current_revision_sequence + 1

    content = %{
      action_id: answer.action_id,
      answer_content_hash: answer.content_hash,
      decision_id: context.decision_id,
      decision_version: context.decision_version,
      prior_action_id: context.current_action_id,
      reason: reason,
      sequence: sequence
    }

    %__MODULE__{
      decision_id: context.decision_id,
      decision_version: context.decision_version,
      sequence: sequence,
      action_id: answer.action_id,
      prior_action_id: context.current_action_id,
      answer: answer,
      reason: reason,
      recorded_at: answer.accepted_at,
      content_hash: DecisionValidation.content_hash(content)
    }
  end

  defp required_string(payload, key) do
    case get(payload, key) do
      value when is_binary(value) -> bounded_identity(value, key)
      nil -> {:error, {key, :missing}}
      _other -> {:error, {key, :invalid_type}}
    end
  end

  defp bounded_identity(value, field) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, {field, :missing}}
      String.length(value) > @identity_max -> {:error, {field, :too_long}}
      unsafe_control_chars?(value) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, value}
    end
  end

  defp required_sequence(payload) do
    case get(payload, :expected_revision_sequence) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      nil -> {:error, {:expected_revision_sequence, :missing}}
      _other -> {:error, {:expected_revision_sequence, :invalid_type}}
    end
  end

  defp compare_action(action_id, action_id), do: :ok

  defp compare_action(expected, current) do
    {:error, {:stale_action, %{expected: expected, current: current}}}
  end

  defp compare_sequence(sequence, sequence), do: :ok

  defp compare_sequence(expected, current) do
    {:error, {:stale_sequence, %{expected: expected, current: current}}}
  end

  defp changed_action(action_id, action_id), do: {:error, {:action_id, :unchanged}}
  defp changed_action(_new_action_id, _prior_action_id), do: :ok

  defp context_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:context, {key, :invalid}}}
    end
  end

  defp context_positive_integer(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:context, {key, :invalid}}}
    end
  end

  defp context_non_negative_integer(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, {:context, {key, :invalid}}}
    end
  end

  defp context_datetime(opts, key) do
    case Keyword.get(opts, key) do
      %DateTime{} = value -> {:ok, value}
      _other -> {:error, {:context, {key, :invalid}}}
    end
  end

  defp context_map(opts, key) do
    case Keyword.get(opts, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:context, {key, :invalid}}}
    end
  end

  defp context_normalizer(opts) do
    case Keyword.get(opts, :answer_normalizer) do
      normalizer when is_function(normalizer, 2) -> {:ok, normalizer}
      _other -> {:error, {:context, {:answer_normalizer, :invalid}}}
    end
  end

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp get(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
