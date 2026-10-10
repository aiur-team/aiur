defmodule Aiur.ModelDiscovery.Fetch do
  @moduledoc false

  # Catalogue sources: id validation, the OpenAI-compatible endpoint and its fetch.

  alias Aiur.CodingAgent

  @request_timeout_ms 30_000

  def ingest(models) do
    {kept, refused} =
      Enum.reduce(models, {[], []}, fn model, {kept, refused} ->
        case rejection_reason(Map.get(model, :id)) do
          nil -> {[encode_model(model) | kept], refused}
          reason -> {kept, [%{"id" => inspect_id(Map.get(model, :id)), "reason" => to_string(reason)} | refused]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(refused)}
  end

  defp rejection_reason(id) when is_binary(id) do
    cond do
      String.trim(id) == "" -> :empty_identifier
      String.starts_with?(id, "~") -> :unstable_identifier_prefix
      String.contains?(id, ":") -> :reserved_routing_separator
      true -> nil
    end
  end

  defp rejection_reason(_id), do: :invalid_identifier

  defp inspect_id(id) when is_binary(id), do: id
  defp inspect_id(id), do: inspect(id)

  defp encode_model(model) do
    model
    |> Map.new(fn {key, value} -> {to_string(key), encode_value(value)} end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp encode_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp encode_value(%{} = value), do: Map.new(value, fn {key, inner} -> {to_string(key), encode_value(inner)} end)
  defp encode_value(value), do: value

  def fetch_source(backend) do
    case source_module(backend) do
      nil -> {:error, {:model_discovery_unsupported, backend}}
      module -> {:ok, module}
    end
  end

  def source_module(backend) do
    case get_in(CodingAgent.backends(), [backend, :openai_compat, :models_endpoint]) do
      module when is_atom(module) and not is_nil(module) -> module
      _other -> nil
    end
  end

  def instance(backend), do: get_in(CodingAgent.backends(), [backend, :openai_compat]) || %{}

  def api_key(backend, opts) do
    fetcher = Keyword.get(opts, :api_key_fetcher, &System.get_env/1)

    case backend |> instance() |> Map.get(:api_key_env) do
      env when is_binary(env) -> fetcher.(env)
      _other -> nil
    end
  end

  def fetch(request, opts) do
    fetch_fun = Keyword.get(opts, :fetch, &default_fetch/1)

    case fetch_fun.(request) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:model_catalog_status, status}}
      {:error, reason} -> {:error, {:model_catalog_request, reason}}
      other -> {:error, {:model_catalog_request, other}}
    end
  end

  defp default_fetch(%{url: url, headers: headers}) do
    case Req.get(url, headers: headers, receive_timeout: @request_timeout_ms, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
