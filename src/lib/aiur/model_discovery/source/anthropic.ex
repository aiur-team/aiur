defmodule Aiur.ModelDiscovery.Source.Anthropic do
  @moduledoc """
  The Anthropic `GET /v1/models` shape: `x-api-key` plus a pinned
  `anthropic-version`, and a `data` array of `id` / `display_name` pairs.

  The catalogue reports **identifiers and display names only** — no pricing.

  No registry backend declares this source today: `claude` and `claude-repl`
  reach Anthropic through their own CLI, and `Aiur.ModelCatalog` already asks
  that CLI what it accepts, which is the more authoritative answer because the
  CLI is the thing that has to take the string. This adapter exists so an
  operator who points an OpenAI-compatible backend straight at the Anthropic
  API gets the same discovery every other provider gets, without a second
  mechanism being invented for it.
  """

  @behaviour Aiur.ModelDiscovery.Source

  alias Aiur.ModelDiscovery.Source

  # Pinned rather than tracked: the models endpoint's response shape is stable
  # under this version, and a silently newer one could change it.
  @api_version "2023-06-01"

  @impl Source
  def request(instance, api_key) when is_binary(api_key) and api_key != "" do
    {:ok,
     %{
       url: Source.models_url(instance),
       headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}]
     }}
  end

  def request(instance, _api_key), do: {:error, {:missing_api_key, Map.get(instance, :api_key_env)}}

  @impl Source
  def parse(%{"data" => data}) when is_list(data) do
    {:ok, Enum.flat_map(data, &model/1)}
  end

  def parse(_body), do: {:error, {:unexpected_model_list, __MODULE__}}

  defp model(%{"id" => id} = entry) do
    Source.model(id, %{display_name: Source.display_name(Map.get(entry, "display_name"))})
  end

  defp model(_entry), do: []
end
