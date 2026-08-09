defmodule Aiur.OpenAICompat.Config do
  @moduledoc false

  alias Aiur.CodingAgent
  alias Aiur.Config, as: AiurConfig

  @required ~w(base_url api_key_env transport)a

  @spec resolve(keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(opts) when is_list(opts) do
    backend = Keyword.get(opts, :backend)

    with true <- is_binary(backend) or {:error, :missing_backend},
         {:ok, instance} <- instance_config(backend, opts),
         {:ok, runtime_config} <- backend_config(backend, opts),
         config <- merge_runtime_config(instance, runtime_config),
         {:ok, config} <- validate(config),
         {:ok, api_key} <- fetch_api_key(config.api_key_env, opts),
         {:ok, model} <- resolve_model(config, opts) do
      {:ok,
       config
       |> Map.put(:backend, backend)
       |> Map.put(:api_key, api_key)
       |> Map.put(:model, model)
       |> Map.put(:request_fun, Keyword.get(opts, :request_fun, &request/1))}
    end
  end

  defp instance_config(_backend, opts) do
    case Keyword.get(opts, :instance) do
      %{} = instance -> {:ok, atomize(instance)}
      nil -> registry_instance(Keyword.fetch!(opts, :backend))
      _ -> {:error, :invalid_instance_config}
    end
  end

  defp registry_instance(backend) do
    case get_in(CodingAgent.backends(), [backend, :openai_compat]) do
      %{} = instance -> {:ok, atomize(instance)}
      _ -> {:error, {:missing_openai_compat_registry_config, backend}}
    end
  end

  defp backend_config(backend, opts) do
    case Keyword.get(opts, :backend_config) do
      %{} = config ->
        {:ok, atomize(config)}

      nil ->
        fetch_backend_config(backend, opts)

      _ ->
        {:error, :invalid_backend_config}
    end
  end

  defp fetch_backend_config(backend, opts) do
    fetcher = Keyword.get(opts, :backend_config_fetcher, &AiurConfig.backend_config/1)

    case fetcher.(backend) do
      %{} = config -> {:ok, atomize(config)}
      _ -> {:error, :invalid_backend_config}
    end
  rescue
    error -> {:error, {:backend_config_unavailable, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:backend_config_unavailable, {kind, reason}}}
  end

  defp merge_runtime_config(instance, runtime) do
    quirks = Map.merge(Map.get(instance, :quirks, %{}), Map.get(runtime, :quirks, %{}))
    instance |> Map.merge(Map.delete(runtime, :quirks)) |> Map.put(:quirks, quirks)
  end

  defp validate(config) do
    missing = Enum.reject(@required, &valid_required?(config, &1))

    cond do
      missing != [] -> {:error, {:missing_openai_compat_config, missing}}
      config.transport not in [:chat_completions, :responses] -> {:error, {:unsupported_transport, config.transport}}
      true -> {:ok, config}
    end
  end

  defp valid_required?(config, :transport), do: Map.get(config, :transport) in [:chat_completions, :responses]
  defp valid_required?(config, key), do: is_binary(Map.get(config, key)) and String.trim(Map.fetch!(config, key)) != ""

  defp fetch_api_key(env_name, opts) do
    fetcher = Keyword.get(opts, :api_key_fetcher, &System.get_env/1)

    case fetcher.(env_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_api_key, env_name}}
    end
  end

  defp resolve_model(config, opts) do
    model = Keyword.get(opts, :model) || Map.get(config, :model) || Map.get(config, :default_model)
    if is_binary(model) and String.trim(model) != "", do: {:ok, model}, else: {:error, :missing_model}
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {safe_key(key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  defp atomize_value(value) when is_map(value), do: atomize(value)
  defp atomize_value("chat_completions"), do: :chat_completions
  defp atomize_value("responses"), do: :responses
  defp atomize_value(value), do: value

  # Only these string keys become atoms. Anything else stays a binary, so an
  # attacker-supplied config key cannot exhaust the atom table.
  @known_keys Map.new(
                ~w(base_url api_key_env model default_model transport quirks management_api_key_env
                   reasoning_content_replay text_tool_fallback openrouter_metadata local_concurrency_limit),
                &{&1, String.to_atom(&1)}
              )

  defp safe_key(key), do: Map.get(@known_keys, key, key)

  defp request(%{url: url, headers: headers, json: json}) do
    case Req.post(url, headers: Map.to_list(headers), json: json, receive_timeout: 300_000, retry: false) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body, headers: normalize_headers(response.headers)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Req hands back a map, but a list of pairs normalizes identically.
  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value |> List.wrap() |> List.first()} end)
  end
end
