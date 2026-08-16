defmodule Aiur.ModelDiscovery.Source.OpenAI do
  @moduledoc """
  The OpenAI `GET /v1/models` shape, which DeepSeek and Moonshot both copy
  verbatim: bearer auth, and a `data` array whose members carry an `id` and
  nothing else worth keeping.

  These catalogues report **identifiers only** — no context window and no
  pricing. A model discovered here is therefore usable but unpriced until a
  curated row exists for it (see `Aiur.ModelDiscovery`), and unpriced usage
  reports unknown cost rather than zero.
  """

  @behaviour Aiur.ModelDiscovery.Source

  alias Aiur.ModelDiscovery.Source

  @impl Source
  def request(instance, api_key) when is_binary(api_key) and api_key != "" do
    {:ok, %{url: Source.models_url(instance), headers: [{"authorization", "Bearer " <> api_key}]}}
  end

  def request(instance, _api_key), do: {:error, {:missing_api_key, Map.get(instance, :api_key_env)}}

  @impl Source
  def parse(%{"data" => data}) when is_list(data) do
    {:ok, Enum.flat_map(data, &model/1)}
  end

  def parse(_body), do: {:error, {:unexpected_model_list, __MODULE__}}

  defp model(%{"id" => id}), do: Source.model(id)
  defp model(_entry), do: []
end
