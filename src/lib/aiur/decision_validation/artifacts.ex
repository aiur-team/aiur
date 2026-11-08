defmodule Aiur.DecisionValidation.Artifacts do
  @moduledoc """
  Bounded artifact references on a Decision request.

  Ingress shape (a fresh, unvalidated agent payload) is a raw path/URL string.
  Replay feeds back the *persisted* shape instead — the
  `%{"kind" =>, "value" =>}` map `Aiur.DecisionProjection.to_json_safe/1`
  writes — so both are accepted here, re-running the extracted value through
  the same `Aiur.DecisionArtifact` validator either way (full re-validation on
  replay, not a trust-the-shape shortcut).
  """

  alias Aiur.DecisionArtifact

  @artifacts_max 20
  @artifact_value_max 4_096

  @type error :: {:artifacts, atom()}

  @spec fetch(map(), [Path.t()]) :: {:ok, [DecisionArtifact.t()]} | {:error, error()}
  def fetch(payload, safe_roots) when is_map(payload) and is_list(safe_roots) do
    case get(payload, :artifacts) do
      nil ->
        {:ok, []}

      list when is_list(list) and length(list) > @artifacts_max ->
        {:error, {:artifacts, :too_many}}

      list when is_list(list) ->
        normalize(list, safe_roots, [])

      _other ->
        {:error, {:artifacts, :invalid_type}}
    end
  end

  defp normalize([], _safe_roots, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize([raw | rest], safe_roots, acc) when is_binary(raw) do
    validate(raw, rest, safe_roots, acc)
  end

  defp normalize([%{"value" => value} | rest], safe_roots, acc) when is_binary(value) do
    validate(value, rest, safe_roots, acc)
  end

  defp normalize([_invalid | _rest], _safe_roots, _acc), do: {:error, {:artifacts, :invalid_type}}

  defp validate(value, _rest, _safe_roots, _acc) when byte_size(value) > @artifact_value_max do
    {:error, {:artifacts, :too_long}}
  end

  defp validate(value, rest, safe_roots, acc) do
    case DecisionArtifact.validate(value, safe_roots) do
      {:ok, artifact} -> normalize(rest, safe_roots, [artifact | acc])
      {:error, reason} -> {:error, {:artifacts, reason}}
    end
  end

  defp get(payload, key), do: Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
end
