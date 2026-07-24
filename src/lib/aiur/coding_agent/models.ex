defmodule Aiur.CodingAgent.Models do
  @moduledoc """
  Grammar of a backend model string, plus the family/latest-version
  resolution built on it.

  A model id is `<prefix>-<version>[-<tier>]` (`gpt-5.6-sol`, `gpt-5.5`).
  Its **family** is the tier when it has one, else the prefix — so
  `gpt-5.6-sol` and a future `gpt-5.7-sol` share the family `sol`, while
  `gpt-5.5` and `gpt-5.4` share `gpt`. That makes a family name usable as a
  generic alias that always means "the newest model in this family", which
  is what keeps a routing table from going stale every time a version is
  retired.

  Ids that do not match the grammar (a bare `o3`, a provider-specific
  string) simply carry no family. They stay perfectly valid as explicitly
  pinned models; they just contribute no alias.
  """

  # Anchored so a stray suffix can't be silently absorbed into the tier.
  @model ~r/^(?<prefix>[a-z]+)-(?<version>\d+(?:\.\d+)*)(?:-(?<tier>[a-z][a-z0-9]*))?$/

  @type parsed :: %{prefix: String.t(), version: [non_neg_integer()], tier: String.t() | nil}

  @doc """
  Parses a model id into its prefix, numeric version segments, and optional
  tier. `:error` for anything that is not `<prefix>-<version>[-<tier>]`.
  """
  @spec parse(term()) :: {:ok, parsed()} | :error
  def parse(model) when is_binary(model) do
    case Regex.named_captures(@model, model) do
      nil ->
        :error

      captures ->
        {:ok,
         %{
           prefix: captures["prefix"],
           version: version_segments(captures["version"]),
           tier: presence(captures["tier"])
         }}
    end
  end

  def parse(_model), do: :error

  @doc """
  The family a model id belongs to — its tier when it has one, else its
  prefix — or `nil` when the id does not parse.
  """
  @spec family(term()) :: String.t() | nil
  def family(model) do
    case parse(model) do
      {:ok, %{tier: tier}} when is_binary(tier) -> tier
      {:ok, %{prefix: prefix}} -> prefix
      :error -> nil
    end
  end

  @doc """
  Generic family aliases derivable from `models`, in the order each family
  first appears. Preserving list order keeps the registry's own
  most-capable-first intent, which is the order `aiur init` offers and
  seeds labels in.

  A family name that is itself a concrete id in the list is dropped: the
  pinned meaning has to win, or `resolve/2` would quietly redirect an
  explicit pin.
  """
  @spec aliases([String.t()]) :: [String.t()]
  def aliases(models) when is_list(models) do
    models
    |> Enum.map(&family/1)
    |> Enum.reject(&(is_nil(&1) or &1 in models))
    |> Enum.uniq()
  end

  @doc """
  The newest concrete model in `family` within `models`, comparing version
  segments numerically, or `nil` when `family` names no family in the list.

  A `nil` return is how callers tell "this string was a pinned model, pass
  it through" apart from "this was an alias, here is what it resolves to".
  """
  @spec latest([String.t()], term()) :: String.t() | nil
  def latest(models, family) when is_list(models) and is_binary(family) do
    if family in models do
      nil
    else
      models
      |> Enum.filter(&(family(&1) == family))
      |> Enum.max_by(&version_of/1, fn -> nil end)
    end
  end

  def latest(_models, _family), do: nil

  defp version_of(model) do
    case parse(model) do
      {:ok, %{version: version}} -> version
      :error -> []
    end
  end

  defp version_segments(version) do
    version |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
