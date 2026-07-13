defmodule Aiur.DecisionAuthority do
  @moduledoc """
  Evaluates whether the configured supervising agent may mutate a Decision.

  The policy is deliberately narrowing: `human_required` is absolute, a kind
  must appear in the explicit allowlist, and non-reversible work needs a second
  opt-in. Missing or malformed policy data always evaluates as the safe default.
  """

  @delegable_authorities [:supervisor_allowed, :supervisor_preferred]
  @non_reversible [:irreversible, :partially_reversible]

  @type policy :: %{
          optional(:allowed_kinds) => [String.t()],
          optional(:allow_non_reversible) => boolean()
        }

  @type reason ::
          :human_required
          | :authority_not_delegable
          | :kind_missing
          | :kind_not_allowed
          | :non_reversible_not_allowed
          | :reversibility_not_delegable

  @type evaluation :: %{
          allowed: boolean(),
          authority: term(),
          kind: term(),
          reversibility: term(),
          checks: %{
            authority_delegable: boolean(),
            kind_allowed: boolean(),
            reversibility_allowed: boolean()
          },
          policy: %{allowed_kinds: [String.t()], allow_non_reversible: boolean()},
          reasons: [reason()]
        }

  @doc "Returns a deterministic, fail-closed policy evaluation for one Decision."
  @spec evaluate(map(), policy() | term()) :: evaluation()
  def evaluate(%{authority: authority, kind: kind, reversibility: reversibility}, policy) do
    normalized_policy = normalize_policy(policy)
    {authority_delegable, authority_reason} = evaluate_authority(authority)
    {kind_allowed, kind_reason} = evaluate_kind(kind, normalized_policy.allowed_kinds)

    {reversibility_allowed, reversibility_reason} =
      evaluate_reversibility(reversibility, normalized_policy.allow_non_reversible)

    reasons = Enum.reject([authority_reason, kind_reason, reversibility_reason], &is_nil/1)

    %{
      allowed: reasons == [],
      authority: authority,
      kind: kind,
      reversibility: reversibility,
      checks: %{
        authority_delegable: authority_delegable,
        kind_allowed: kind_allowed,
        reversibility_allowed: reversibility_allowed
      },
      policy: normalized_policy,
      reasons: reasons
    }
  end

  def evaluate(decision, policy) when is_map(decision) do
    evaluate(
      %{
        authority: Map.get(decision, :authority),
        kind: Map.get(decision, :kind),
        reversibility: Map.get(decision, :reversibility)
      },
      policy
    )
  end

  defp normalize_policy(%{allowed_kinds: allowed_kinds} = policy) when is_list(allowed_kinds) do
    %{
      allowed_kinds:
        allowed_kinds
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&normalize_kind/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort(),
      allow_non_reversible: Map.get(policy, :allow_non_reversible) == true
    }
  end

  defp normalize_policy(_policy), do: %{allowed_kinds: [], allow_non_reversible: false}

  defp evaluate_authority(:human_required), do: {false, :human_required}
  defp evaluate_authority(authority) when authority in @delegable_authorities, do: {true, nil}
  defp evaluate_authority(_authority), do: {false, :authority_not_delegable}

  defp evaluate_kind(kind, allowed_kinds) do
    case normalize_kind(kind) do
      nil -> {false, :kind_missing}
      normalized -> if normalized in allowed_kinds, do: {true, nil}, else: {false, :kind_not_allowed}
    end
  end

  defp normalize_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_kind(_kind), do: nil

  defp evaluate_reversibility(:reversible, _allow_non_reversible), do: {true, nil}

  defp evaluate_reversibility(reversibility, true) when reversibility in @non_reversible,
    do: {true, nil}

  defp evaluate_reversibility(reversibility, false) when reversibility in @non_reversible,
    do: {false, :non_reversible_not_allowed}

  defp evaluate_reversibility(_reversibility, _allow_non_reversible),
    do: {false, :reversibility_not_delegable}
end
