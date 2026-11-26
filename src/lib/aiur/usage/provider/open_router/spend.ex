defmodule Aiur.Usage.Provider.OpenRouter.Spend do
  @moduledoc """
  Prices the retained OpenRouter aggregate cells into per-route, per-model
  spend.

  OpenRouter reports no cost of its own in a completion, so a spend figure for
  its routes is an API-equivalent estimate re-priced from the exact retained
  token counts. That pricing is delegated to
  `Aiur.Usage.GroupedScopes.Projection` — the same authority the dashboard's
  grouped usage query uses — so a cached-input remainder or a peak-window rate
  is priced identically on both surfaces. Provider-reported money is kept in its
  own bucket and never added to the API-equivalent estimate.
  """

  alias Aiur.Usage.GroupedScopes.Projection
  alias Aiur.Usage.Headless.Catalog
  alias Aiur.Usage.PriceTable

  @provider :openrouter
  @default_currency "USD"

  @type entry :: %{
          upstream: String.t() | nil,
          model: String.t() | nil,
          currency: String.t(),
          amount: String.t()
        }

  @doc """
  Groups OpenRouter spend by `{upstream provider, resolved model}`.

  Returns `%{api_equivalent: [entry], provider_reported: [entry]}`. A missing or
  unreadable aggregate source yields two empty lists: a spend figure that cannot
  be computed is absent, never zero.
  """
  @spec by_model(map() | nil, keyword()) :: %{api_equivalent: [entry()], provider_reported: [entry()]}
  def by_model(source, opts \\ [])

  def by_model(%{cells: cells}, opts) when not is_nil(cells) do
    currency = Keyword.get(opts, :currency, @default_currency)

    case PriceTable.default() do
      {:ok, price_table} ->
        selected = Enum.filter(cells, fn {{dims, _measure}, _value} -> dims.provider == @provider end)
        entries = Projection.token_entries(selected, currency, price_table, Catalog.relationship_catalog())

        %{
          api_equivalent: group(entries, :api),
          provider_reported: group(Projection.money_entries(selected), :provider_reported)
        }

      {:error, _reason} ->
        empty()
    end
  rescue
    _error -> empty()
  catch
    _kind, _reason -> empty()
  end

  def by_model(_source, _opts), do: empty()

  @doc "The retained aggregate source, read from the running daemon."
  @spec default_source() :: map() | nil
  def default_source do
    Aiur.UsageAggregate.cells_snapshot()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp empty, do: %{api_equivalent: [], provider_reported: []}

  defp group(entries, :api) do
    entries
    |> Enum.filter(&match?(%{priced: {:ok, %{amount: %Decimal{}}}}, &1))
    |> Enum.reduce(%{}, fn %{dims: dims, priced: {:ok, %{amount: amount, currency: currency}}}, acc ->
      accumulate(acc, dims, currency, amount)
    end)
    |> present()
  end

  defp group(entries, :provider_reported) do
    Enum.reduce(entries, %{}, fn %{dims: dims, currency: currency, amount: amount}, acc ->
      accumulate(acc, dims, currency, amount)
    end)
    |> present()
  end

  defp accumulate(acc, dims, currency, amount) do
    Map.update(acc, {dims.upstream_provider, dims.resolved_model, currency}, amount, &Decimal.add(&1, amount))
  end

  defp present(groups) do
    groups
    |> Enum.map(fn {{upstream, model, currency}, amount} ->
      %{upstream: upstream, model: model, currency: currency, amount: Decimal.to_string(amount, :normal)}
    end)
    |> Enum.sort_by(&{&1.upstream || "", &1.model || "", &1.currency})
  end
end
