defmodule Aiur.CodingAgent.Models do
  @moduledoc """
  Pure helpers for deriving stable family aliases from versioned model ids.

  Codex model ids currently use `<prefix>-<version>[-<tier>]`, for example
  `gpt-5.6-sol` and `gpt-5.5-mini`. The tier is the useful stable alias when
  present; otherwise the prefix is the family (`gpt`). Unknown id shapes remain
  usable as explicit pins but do not synthesize an alias.
  """

  @model_id ~r/^(?<prefix>[A-Za-z][A-Za-z0-9]*)-(?<version>\d+(?:\.\d+)*)(?:-(?<tier>[A-Za-z][A-Za-z0-9]*))?$/

  @spec aliases([String.t()]) :: %{String.t() => String.t()}
  def aliases(models) when is_list(models) do
    concrete = MapSet.new(models)

    models
    |> Enum.flat_map(&alias_candidate/1)
    |> Enum.reject(fn {family, _version, _model} -> MapSet.member?(concrete, family) end)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {family, candidates} ->
      {_family, _version, model} = Enum.max_by(candidates, fn {_family, version, model} -> {version, model} end)
      {family, model}
    end)
  end

  def aliases(_models), do: %{}

  @spec alias_candidate(term()) :: [{String.t(), [non_neg_integer()], String.t()}]
  defp alias_candidate(model) when is_binary(model) do
    case Regex.named_captures(@model_id, model) do
      %{"prefix" => prefix, "version" => version, "tier" => tier} ->
        family = if tier == "", do: prefix, else: tier
        [{family, parse_version(version), model}]

      _ ->
        []
    end
  end

  defp alias_candidate(_model), do: []

  defp parse_version(version) do
    version
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
  end
end
