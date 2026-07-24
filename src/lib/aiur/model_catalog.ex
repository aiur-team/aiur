defmodule Aiur.ModelCatalog do
  @moduledoc """
  Best-effort model discovery through each installed backend's app-server.

  Discovery is deliberately optional: a missing CLI, an offline provider, or
  an unexpected response returns `{:error, reason}` and never prevents init or
  dispatch. Successful runtime probes are cached briefly so concurrent agent
  starts do not each launch another app-server.
  """

  alias Aiur.AppServer.{Adapter, Messages, Rpc}
  alias Aiur.CodingAgent
  alias Aiur.Codex.AppServerPort

  @request_id 2
  @timeout_ms 5_000
  @cache_ttl_ms 300_000
  @cache_key {__MODULE__, :models}

  @type result :: {:ok, [String.t()]} | {:error, term()}

  @spec discover([CodingAgent.backend()], keyword()) :: %{CodingAgent.backend() => result()}
  def discover(backends, opts \\ []) when is_list(backends) do
    Map.new(Enum.uniq(backends), &{&1, models(&1, opts)})
  end

  @spec models(CodingAgent.backend(), keyword()) :: result()
  def models(backend, opts \\ []) when is_binary(backend) do
    case Keyword.get(opts, :probe_fun) do
      fun when is_function(fun, 1) -> normalize_probe_result(fun.(backend))
      _fun -> cached_models(backend, opts)
    end
  rescue
    error -> {:error, {:model_discovery_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:model_discovery_failed, {kind, reason}}}
  end

  defp cached_models(backend, opts) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, %{}) do
      %{^backend => {stored_at, result}} when now - stored_at < @cache_ttl_ms ->
        result

      cache ->
        result = probe(backend, opts)
        :persistent_term.put(@cache_key, Map.put(cache, backend, {now, result}))
        result
    end
  end

  defp probe(backend, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, command} <- command_for(backend),
         {:ok, port} <- Adapter.start_port(workspace, command) do
      try do
        query(port, backend, timeout)
      after
        AppServerPort.stop_port(port)
      end
    end
  end

  defp command_for(backend) do
    case CodingAgent.catalog_family(backend) do
      "codex" -> {:ok, Aiur.Codex.Config.command()}
      "claude" -> {:ok, Aiur.Claude.Config.command()}
      nil -> {:error, {:unsupported_backend, backend}}
    end
  end

  defp query(port, backend, timeout) do
    Rpc.send_line(port, Messages.initialize_frame())

    with {:ok, _initialize} <- Rpc.with_timeout_response(port, Messages.initialize_id(), timeout, "", backend),
         true <- Rpc.send_line(port, Messages.initialized_frame()),
         true <- Rpc.send_line(port, %{"method" => "model/list", "id" => @request_id, "params" => %{}}),
         {:ok, response} <- Rpc.with_timeout_response(port, @request_id, timeout, "", backend) do
      normalize_response(response)
    else
      false -> {:error, :port_closed}
      {:error, _reason} = error -> error
    end
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @doc false
  @spec normalize_response(term()) :: result()
  def normalize_response(%{"data" => models}) when is_list(models) do
    models =
      models
      |> Enum.reject(&(is_map(&1) and Map.get(&1, "hidden") == true))
      |> Enum.flat_map(fn
        %{} = model -> [Map.get(model, "model") || Map.get(model, "id")]
        model -> [model]
      end)
      |> normalize_models()

    if models == [], do: {:error, :empty_model_catalog}, else: {:ok, models}
  end

  def normalize_response(%{"models" => models}) when is_list(models) do
    models =
      models
      |> Enum.flat_map(fn
        %{} = model -> [Map.get(model, "id") | List.wrap(Map.get(model, "aliases"))]
        model -> [model]
      end)
      |> normalize_models()

    if models == [], do: {:error, :empty_model_catalog}, else: {:ok, models}
  end

  def normalize_response(payload), do: {:error, {:unexpected_model_catalog, payload}}

  defp normalize_probe_result({:ok, models}) when is_list(models) do
    models = normalize_models(models)
    if models == [], do: {:error, :empty_model_catalog}, else: {:ok, models}
  end

  defp normalize_probe_result({:error, _reason} = error), do: error
  defp normalize_probe_result(other), do: {:error, {:unexpected_model_catalog, other}}

  defp normalize_models(models) do
    models
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
