defmodule Aiur.ModelDiscovery.PriceDrift do
  @moduledoc false

  # Pure comparison of discovered prices against the curated price table.

  alias Aiur.{CodingAgent, ModelDiscovery}
  alias Aiur.Usage.PriceTable

  @drift_threshold Decimal.new("0.05")

  @spec unpriced_models(CodingAgent.backend(), keyword()) :: [String.t()]
  def unpriced_models(backend, opts \\ []) do
    with {:ok, catalog} <- price_catalog(opts),
         provider when is_atom(provider) <- price_provider(backend, catalog) do
      priced = MapSet.new(catalog.entries, & &1.resolved_model)

      backend
      |> ModelDiscovery.cached_models(opts)
      |> Enum.reject(&MapSet.member?(priced, &1))
    else
      _other -> ModelDiscovery.cached_models(backend, opts)
    end
  end

  @spec price_drift(CodingAgent.backend(), keyword()) :: [map()]
  def price_drift(backend, opts \\ []) do
    with {:ok, catalog} <- price_catalog(opts),
         provider when is_atom(provider) <- price_provider(backend, catalog) do
      on = Keyword.get_lazy(opts, :on, &Date.utc_today/0)
      threshold = Keyword.get(opts, :threshold, @drift_threshold)

      backend
      |> ModelDiscovery.cached_entries(opts)
      |> Enum.flat_map(&model_drift(&1, catalog, provider, on, threshold))
    else
      _other -> []
    end
  end

  defp model_drift(model, catalog, provider, on, threshold) do
    id = Map.get(model, "id")

    model
    |> Map.get("pricing", %{})
    |> Enum.flat_map(fn {dimension, quoted} ->
      drift_entry(catalog, provider, id, dimension, quoted, on, threshold)
    end)
  end

  defp drift_entry(catalog, provider, id, dimension, quoted, on, threshold) do
    with %Decimal{} = discovered <- decimal(quoted),
         %{price: curated} <- curated_price(catalog, provider, id, dimension, on),
         %Decimal{} = drift <- relative_drift(curated, discovered),
         :gt <- Decimal.compare(drift, threshold) do
      [
        %{
          provider: provider,
          resolved_model: id,
          token_dimension: dimension,
          curated: curated,
          discovered: discovered,
          relative_drift: drift
        }
      ]
    else
      _other -> []
    end
  end

  # The exact-join `PriceTable.lookup/2` needs dimensions a catalogue feed does
  # not report (relationship revision, cache-write duration). Drift is advisory,
  # so it reads the series directly: newest revision in force on `on`.
  defp curated_price(catalog, provider, model, dimension, on) do
    catalog.entries
    |> Enum.filter(&curated_match?(&1, provider, model, dimension, on))
    |> Enum.sort_by(& &1.effective_date, Date)
    |> List.last()
  end

  defp curated_match?(entry, provider, model, dimension, on) do
    entry.provider == provider and entry.resolved_model == model and
      Atom.to_string(entry.token_dimension) == to_string(dimension) and
      Date.compare(entry.effective_date, on) in [:lt, :eq]
  end

  # Scaled by the larger of the two rather than by the curated one, so a curated
  # row that says "free" and a quote that says otherwise reads as 100% drift
  # instead of dividing by zero and going silent.
  defp relative_drift(curated, discovered) do
    scale = Decimal.max(Decimal.abs(curated), Decimal.abs(discovered))

    if Decimal.equal?(scale, 0) do
      Decimal.new(0)
    else
      curated |> Decimal.sub(discovered) |> Decimal.abs() |> Decimal.div(scale)
    end
  end

  defp price_catalog(opts) do
    case Keyword.get(opts, :price_table) do
      %{entries: _entries} = catalog -> {:ok, catalog}
      nil -> PriceTable.default()
      _other -> {:error, :invalid_price_table}
    end
  end

  # The price table keys on a provider atom that equals the backend family.
  # Matching against atoms the catalog already holds means no atom is created
  # from a backend name, and an unpriced provider simply has no match.
  defp price_provider(backend, catalog) do
    family = CodingAgent.family_for(backend) || backend

    catalog.entries
    |> Enum.map(& &1.provider)
    |> Enum.find(&(Atom.to_string(&1) == family))
  end

  defp decimal(%Decimal{} = value), do: value

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _other -> nil
    end
  end

  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(_value), do: nil
end
