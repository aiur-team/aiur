defmodule Aiur.ModelDiscovery.Source.OpenRouter do
  @moduledoc """
  The OpenRouter `GET /v1/models` catalogue — the only provider surveyed that
  needs **no credential** and that reports **pricing** alongside identifiers.

  Auth is still sent when a key is configured, so the request is attributed to
  the operator's account and rate-limited against it rather than against the
  shared anonymous pool; an absent key is not an error.

  OpenRouter quotes prices in USD *per token*, as strings. They are converted
  here to major USD units per one million tokens, which is the unit
  `Aiur.Usage.PriceTable` entries use (`token_unit: 1_000_000`), so a fetched
  number and a curated number are directly comparable. They are still only
  **advisory** — see `Aiur.ModelDiscovery` for why nothing here is allowed to
  rewrite a curated price row.
  """

  @behaviour Aiur.ModelDiscovery.Source

  alias Aiur.ModelDiscovery.Source

  @token_unit 1_000_000

  # OpenRouter's price keys, mapped onto the token dimensions the price table
  # already retains. Anything else it quotes (per-request, per-image) has no
  # dimension here and is dropped rather than guessed at.
  @dimensions %{
    "prompt" => :input,
    "completion" => :output,
    "input_cache_read" => :cached_input,
    "input_cache_write" => :cache_creation_input
  }

  @impl Source
  def request(instance, api_key) do
    {:ok, %{url: Source.models_url(instance), headers: headers(api_key)}}
  end

  @impl Source
  def parse(%{"data" => data}) when is_list(data) do
    {:ok, Enum.flat_map(data, &model/1)}
  end

  def parse(_body), do: {:error, {:unexpected_model_list, __MODULE__}}

  defp headers(api_key) when is_binary(api_key) and api_key != "", do: [{"authorization", "Bearer " <> api_key}]
  defp headers(_api_key), do: []

  defp model(%{"id" => id} = entry) do
    Source.model(id, %{
      display_name: Source.display_name(Map.get(entry, "name")),
      context_length: Source.context_length(Map.get(entry, "context_length")),
      pricing: pricing(Map.get(entry, "pricing"))
    })
  end

  defp model(_entry), do: []

  defp pricing(%{} = quoted) do
    prices =
      Enum.flat_map(@dimensions, fn {key, dimension} ->
        case per_million(Map.get(quoted, key)) do
          nil -> []
          price -> [{dimension, price}]
        end
      end)

    if prices == [], do: nil, else: Map.new(prices)
  end

  defp pricing(_quoted), do: nil

  # A free model quotes "0"; that is a real price, not a missing one, so it is
  # kept. A non-numeric or negative quote is discarded: an unpriced model is
  # visibly unpriced, which is safe, while a bogus zero would under-report.
  defp per_million(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> non_negative(Decimal.mult(decimal, @token_unit))
      _other -> nil
    end
  end

  defp per_million(value) when is_number(value), do: value |> to_decimal() |> Decimal.mult(@token_unit) |> non_negative()
  defp per_million(_value), do: nil

  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp non_negative(%Decimal{} = decimal) do
    if Decimal.negative?(decimal), do: nil, else: Decimal.normalize(decimal)
  end
end
