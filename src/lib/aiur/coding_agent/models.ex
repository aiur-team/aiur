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

  A second grammar covers **aggregator slugs** — `vendor/model`, as
  OpenRouter names them (`anthropic/claude-sonnet-5`,
  `moonshotai/kimi-k2.7-code`). These never match the id grammar above
  (`claude-sonnet-5` has no numeric segment where the version belongs), so
  without a second rule an aggregator backend could derive no aliases at
  all and `openrouter:claude` would be unusable. For a slug the family is
  the **leading alphabetic run of the model segment** — `claude`, `kimi`,
  `deepseek` — which is the name an operator actually types, and the
  version is every numeric run in that segment, compared in order.

  Two slugs in the same family can tie on version (`claude-sonnet-5` and
  `claude-opus-5`). Ties resolve to the **earlier entry in the list**,
  which for the registry is its deliberate most-capable-first order. That
  makes the choice deterministic rather than incidental; when it matters,
  pin the full slug.

  Ids that do not match either grammar (a bare `o3`, a provider-specific
  string) simply carry no family. They stay perfectly valid as explicitly
  pinned models; they just contribute no alias.
  """

  # Anchored so a stray suffix can't be silently absorbed into the tier.
  @model ~r/^(?<prefix>[a-z]+)-(?<version>\d+(?:\.\d+)*)(?:-(?<tier>[a-z][a-z0-9]*))?$/
  # `vendor/model`. Split on the FIRST slash only: a model id may itself
  # contain slashes, which is how every aggregator that nests namespaces
  # writes them.
  @slug ~r{^(?<vendor>[^/]+)/(?<model>.+)$}
  @slug_family ~r/^[a-z]+/
  @slug_version ~r/\d+(?:\.\d+)*/

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
      :error -> slug_family(model)
    end
  end

  @doc """
  The vendor namespace of an aggregator slug (`anthropic` for
  `anthropic/claude-sonnet-5`), or nil for a plain model id.
  """
  @spec vendor(term()) :: String.t() | nil
  def vendor(model) when is_binary(model) do
    case Regex.named_captures(@slug, model) do
      %{"vendor" => vendor} -> vendor
      nil -> nil
    end
  end

  def vendor(_model), do: nil

  @doc """
  Whether `family` names slugs from **more than one vendor** within
  `models` — `openrouter:claude` when both `anthropic/claude-*` and some
  other vendor's `claude-*` are listed. Resolution would then be a coin
  flip between two differently-priced upstreams, so config validation
  rejects the alias and asks for the full slug instead.
  """
  @spec ambiguous_alias?([String.t()], term()) :: boolean()
  def ambiguous_alias?(models, family) when is_list(models) and is_binary(family) do
    models
    |> Enum.filter(&(family(&1) == family))
    |> Enum.map(&vendor/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length() > 1
  end

  def ambiguous_alias?(_models, _family), do: false

  defp slug_family(model) when is_binary(model) do
    with %{"model" => segment} <- Regex.named_captures(@slug, model),
         [family] <- Regex.run(@slug_family, segment) do
      family
    else
      _ -> nil
    end
  end

  defp slug_family(_model), do: nil

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
      :error -> slug_version(model)
    end
  end

  defp slug_version(model) when is_binary(model) do
    case Regex.named_captures(@slug, model) do
      %{"model" => segment} -> @slug_version |> Regex.scan(segment) |> Enum.flat_map(&version_segments(hd(&1)))
      nil -> []
    end
  end

  defp slug_version(_model), do: []

  defp version_segments(version) do
    version |> String.split(".") |> Enum.map(&String.to_integer/1)
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
