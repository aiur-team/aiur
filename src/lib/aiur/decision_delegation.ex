defmodule Aiur.DecisionDelegation do
  @moduledoc """
  Fail-closed normalization for one supervisor-delegated Decision answer.

  The untrusted payload supplies the answer and bounded reasoning. The policy
  snapshot is always derived from the current canonical Decision and current
  Executor configuration; callers cannot submit or replace it.
  """

  alias Aiur.{Decision, DecisionAuthority, SecretRedactor}

  @rationale_max 4_000
  @alternative_max 500
  @alternatives_max 20
  @kind_max 100
  @answer_fields ~w(custom_response expected_version idempotency_key option_id rationale)
  @reasoning_fields ~w(alternatives_considered confidence reversibility_belief)
  @allowed_fields @answer_fields ++ @reasoning_fields
  @revision_correlation_fields ~w(expected_action_id expected_revision_sequence)
  @revision_allowed_fields @allowed_fields ++ @revision_correlation_fields
  @revision_answer_fields @answer_fields ++ @revision_correlation_fields
  @forbidden_fields ~w(action_id actor authority decision_id decision_version policy policy_basis supervisor_basis)
  @basis_fields ~w(alternatives_considered confidence policy_basis reversibility_belief)
  @policy_fields ~w(allow_non_reversible authority checks kind reversibility)
  @check_fields ~w(authority_delegable kind_allowed reversibility_allowed)
  @delegable_authorities [:supervisor_allowed, :supervisor_preferred]

  @type basis :: %{
          confidence: 0..100,
          alternatives_considered: [String.t()],
          reversibility_belief: Decision.reversibility(),
          policy_basis: %{
            authority: :supervisor_allowed | :supervisor_preferred,
            kind: String.t(),
            reversibility: Decision.reversibility(),
            checks: %{
              authority_delegable: true,
              kind_allowed: true,
              reversibility_allowed: true
            },
            allow_non_reversible: boolean()
          }
        }

  @type normalized :: %{
          answer_payload: map(),
          basis: basis(),
          evaluation: DecisionAuthority.evaluation()
        }

  @doc "Authorizes the current Decision and normalizes its supervisor answer metadata."
  @spec normalize(Decision.t(), map(), DecisionAuthority.policy() | term()) ::
          {:ok, normalized()} | {:error, term()}
  def normalize(%Decision{} = decision, payload, policy) when is_map(payload) do
    evaluation = DecisionAuthority.evaluate(decision, policy)

    if evaluation.allowed do
      normalize_allowed(payload, evaluation, @allowed_fields, @answer_fields)
    else
      {:error,
       {:delegation_forbidden,
        %{
          checks: evaluation.checks,
          reasons: evaluation.reasons
        }}}
    end
  end

  def normalize(%Decision{}, _payload, _policy),
    do: {:error, {:delegation_invalid, {:payload, :invalid_type}}}

  @doc "Authorizes and normalizes a supervisor revision plus OCC-8 correlation fields."
  @spec normalize_revision(Decision.t(), map(), DecisionAuthority.policy() | term()) ::
          {:ok, normalized()} | {:error, term()}
  def normalize_revision(%Decision{} = decision, payload, policy) when is_map(payload) do
    evaluation = DecisionAuthority.evaluate(decision, policy)

    if evaluation.allowed do
      normalize_allowed(payload, evaluation, @revision_allowed_fields, @revision_answer_fields)
    else
      {:error,
       {:delegation_forbidden,
        %{
          checks: evaluation.checks,
          reasons: evaluation.reasons
        }}}
    end
  end

  def normalize_revision(%Decision{}, _payload, _policy),
    do: {:error, {:delegation_invalid, {:payload, :invalid_type}}}

  @doc "Revalidates a canonical or decoded persisted supervisor basis."
  @spec validate_basis(map()) :: {:ok, basis()} | {:error, term()}
  def validate_basis(raw) when is_map(raw) do
    with {:ok, basis} <- normalize_keys(raw),
         :ok <- validate_exact_fields(basis, @basis_fields, :supervisor_basis),
         {:ok, confidence} <- confidence(Map.get(basis, "confidence")),
         {:ok, alternatives} <- alternatives(Map.get(basis, "alternatives_considered")),
         {:ok, belief} <- reversibility(Map.get(basis, "reversibility_belief"), :reversibility_belief),
         {:ok, policy_basis} <- validate_policy_basis(Map.get(basis, "policy_basis")) do
      {:ok,
       %{
         confidence: confidence,
         alternatives_considered: alternatives,
         reversibility_belief: belief,
         policy_basis: policy_basis
       }}
    end
  end

  def validate_basis(_raw), do: {:error, {:supervisor_basis, :invalid_type}}

  @doc "JSON-safe representation included in the immutable DecisionAnswer."
  @spec to_json_safe(basis()) :: map()
  def to_json_safe(basis) do
    %{
      "confidence" => basis.confidence,
      "alternatives_considered" => basis.alternatives_considered,
      "reversibility_belief" => Atom.to_string(basis.reversibility_belief),
      "policy_basis" => %{
        "authority" => Atom.to_string(basis.policy_basis.authority),
        "kind" => basis.policy_basis.kind,
        "reversibility" => Atom.to_string(basis.policy_basis.reversibility),
        "checks" =>
          Map.new(basis.policy_basis.checks, fn {key, value} ->
            {Atom.to_string(key), value}
          end),
        "allow_non_reversible" => basis.policy_basis.allow_non_reversible
      }
    }
  end

  defp normalize_allowed(payload, evaluation, allowed_fields, answer_fields) do
    with {:ok, normalized} <- normalize_keys(payload),
         :ok <- validate_payload_fields(normalized, allowed_fields),
         {:ok, rationale} <- required_text(Map.get(normalized, "rationale"), @rationale_max, :rationale),
         {:ok, confidence} <- confidence(Map.get(normalized, "confidence")),
         {:ok, alternatives} <- alternatives(Map.get(normalized, "alternatives_considered")),
         {:ok, belief} <-
           reversibility(Map.get(normalized, "reversibility_belief"), :reversibility_belief) do
      basis = %{
        confidence: confidence,
        alternatives_considered: alternatives,
        reversibility_belief: belief,
        policy_basis: policy_snapshot(evaluation)
      }

      answer_payload =
        normalized
        |> Map.take(answer_fields)
        |> Map.put("rationale", rationale)

      {:ok, %{answer_payload: answer_payload, basis: basis, evaluation: evaluation}}
    else
      {:error, reason} -> {:error, {:delegation_invalid, reason}}
    end
  end

  defp validate_payload_fields(payload, allowed_fields) do
    keys = Map.keys(payload)
    forbidden = keys |> Enum.filter(&(&1 in @forbidden_fields)) |> Enum.sort()
    unknown = keys |> Enum.reject(&(&1 in allowed_fields or &1 in @forbidden_fields)) |> Enum.sort()

    cond do
      forbidden != [] -> {:error, {:forbidden_fields, forbidden}}
      unknown != [] -> {:error, {:unknown_fields, unknown}}
      true -> :ok
    end
  end

  defp policy_snapshot(evaluation) do
    %{
      authority: evaluation.authority,
      kind: evaluation.kind |> String.trim() |> String.downcase(),
      reversibility: evaluation.reversibility,
      checks: evaluation.checks,
      allow_non_reversible: evaluation.policy.allow_non_reversible
    }
  end

  defp validate_policy_basis(raw) when is_map(raw) do
    with {:ok, policy} <- normalize_keys(raw),
         :ok <- validate_exact_fields(policy, @policy_fields, :policy_basis),
         {:ok, authority} <- enum(Map.get(policy, "authority"), @delegable_authorities, :authority),
         {:ok, kind} <- required_text(Map.get(policy, "kind"), @kind_max, :kind),
         {:ok, reversibility} <- reversibility(Map.get(policy, "reversibility"), :reversibility),
         {:ok, checks} <- validate_checks(Map.get(policy, "checks")),
         {:ok, allow_non_reversible} <- required_boolean(Map.get(policy, "allow_non_reversible")),
         :ok <- validate_reversibility_policy(reversibility, allow_non_reversible) do
      {:ok,
       %{
         authority: authority,
         kind: String.downcase(kind),
         reversibility: reversibility,
         checks: checks,
         allow_non_reversible: allow_non_reversible
       }}
    end
  end

  defp validate_policy_basis(_raw), do: {:error, {:policy_basis, :invalid_type}}

  defp validate_checks(raw) when is_map(raw) do
    with {:ok, checks} <- normalize_keys(raw),
         :ok <- validate_exact_fields(checks, @check_fields, :checks),
         true <- Enum.all?(@check_fields, &(Map.get(checks, &1) == true)) do
      {:ok,
       %{
         authority_delegable: true,
         kind_allowed: true,
         reversibility_allowed: true
       }}
    else
      false -> {:error, {:checks, :not_allowed}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_checks(_raw), do: {:error, {:checks, :invalid_type}}

  defp validate_exact_fields(map, expected, location) do
    keys = Map.keys(map)
    missing = Enum.sort(expected -- keys)
    unknown = Enum.sort(keys -- expected)

    cond do
      missing != [] -> {:error, {location, {:missing_fields, missing}}}
      unknown != [] -> {:error, {location, {:unknown_fields, unknown}}}
      true -> :ok
    end
  end

  defp confidence(value) when is_integer(value) and value >= 0 and value <= 100, do: {:ok, value}
  defp confidence(_value), do: {:error, {:confidence, :invalid}}

  defp alternatives(values) when is_list(values) and length(values) > @alternatives_max,
    do: {:error, {:alternatives_considered, :too_many}}

  defp alternatives(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case required_text(value, @alternative_max, :alternative) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finalize_alternatives()
  end

  defp alternatives(_values), do: {:error, {:alternatives_considered, :invalid_type}}

  defp finalize_alternatives({:ok, normalized}), do: {:ok, Enum.reverse(normalized)}
  defp finalize_alternatives({:error, reason}), do: {:error, reason}

  defp reversibility(value, field), do: enum(value, Decision.reversibilities(), field)

  defp enum(value, allowed, field) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, {field, :invalid}}
  end

  defp enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {field, :invalid}}
      known -> {:ok, known}
    end
  end

  defp enum(_value, _allowed, field), do: {:error, {field, :invalid}}

  defp required_boolean(value) when is_boolean(value), do: {:ok, value}
  defp required_boolean(_value), do: {:error, {:allow_non_reversible, :invalid}}

  defp validate_reversibility_policy(:reversible, _allow_non_reversible), do: :ok
  defp validate_reversibility_policy(_non_reversible, true), do: :ok
  defp validate_reversibility_policy(_non_reversible, false), do: {:error, {:policy_basis, :inconsistent}}

  defp required_text(value, max, field) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, {field, :missing}}
      String.length(trimmed) > max -> {:error, {field, :too_long}}
      unsafe_control_chars?(trimmed) -> {:error, {field, :unsafe_characters}}
      true -> {:ok, SecretRedactor.redact(trimmed)}
    end
  end

  defp required_text(nil, _max, field), do: {:error, {field, :missing}}
  defp required_text(_value, _max, field), do: {:error, {field, :invalid_type}}

  defp unsafe_control_chars?(text) do
    text
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 and codepoint not in [?\n, ?\t, ?\r] end)
  end

  defp normalize_keys(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      case normalize_key(raw_key) do
        {:ok, key} -> accumulate_key(normalized, key, value)
        :error -> {:halt, {:error, {:field, :invalid}}}
      end
    end)
  end

  defp accumulate_key(normalized, key, value) do
    if Map.has_key?(normalized, key) do
      {:halt, {:error, {:duplicate_fields, [key]}}}
    else
      {:cont, {:ok, Map.put(normalized, key, value)}}
    end
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: :error
end
