defmodule VoiceConverse.Providers do
  @moduledoc """
  The provider registry and credential-presence resolver for a VoiceConverse session.

  This module never opens a connection or receives a secret. It only asks the configured
  credentials port to probe whether a provider is available.
  """

  alias VoiceConverse.Config
  alias VoiceConverse.ProviderPolicy
  alias VoiceConverse.Providers.Registry

  @spec default_preference() :: [atom()]
  def default_preference, do: Config.default_provider_preference()

  @spec credential_env(atom()) :: String.t() | nil
  def credential_env(provider), do: Registry.credential_env(provider)

  @spec options(Config.t()) :: [map()]
  def options(%Config{} = config), do: Enum.map(Registry.entries(), &option(&1, config))

  @spec resolve(Config.t()) ::
          {:ok, map(), skipped: [{atom(), term()}]} | {:error, :no_usable_option, [{atom(), term()}]}
  def resolve(%Config{} = config) do
    {result, skipped} = resolve_preference(config.providers.preference, config, [])

    case result do
      {:ok, option} -> {:ok, option, skipped: Enum.reverse(skipped)}
      :none -> fallback_to_text_only(config, Enum.reverse(skipped))
    end
  end

  defp resolve_preference([], _config, skipped), do: {:none, skipped}

  defp resolve_preference([id | ids], config, skipped) do
    case option_by_id(id, config) do
      nil ->
        resolve_preference(ids, config, [{id, :unknown_option} | skipped])

      %{modes: modes} = option ->
        resolve_option(id, ids, option, modes, config, skipped)
    end
  end

  defp resolve_option(id, ids, option, modes, config, skipped) do
    cond do
      config.providers.mode not in modes ->
        resolve_preference(ids, config, [{id, {:mode_unsupported, config.providers.mode}} | skipped])

      true ->
        resolve_permitted_option(id, ids, option, config, skipped)
    end
  end

  defp resolve_permitted_option(id, ids, option, config, skipped) do
    case ProviderPolicy.check(config.privacy, option) do
      {:error, reason} ->
        resolve_preference(ids, config, [{id, {:policy_refused, reason}} | skipped])

      :ok ->
        resolve_ready_option(id, ids, option, config, skipped)
    end
  end

  defp resolve_ready_option(id, ids, option, config, skipped) do
    cond do
      option.status == :ready ->
        {{:ok, option}, skipped}

      match?({:missing_credential, _provider}, option.reason) and config.providers.on_missing_credential == :refuse ->
        {:none, [{id, option.reason} | skipped]}

      true ->
        resolve_preference(ids, config, [{id, option.reason} | skipped])
    end
  end

  defp fallback_to_text_only(
         %Config{providers: %{on_missing_credential: :text_only}} = config,
         skipped
       ) do
    case option_by_id(:text_only, config) do
      %{status: :ready} = option ->
        resolve_text_only_fallback(option, config, skipped)

      %{reason: reason} ->
        {:error, :no_usable_option, skipped ++ [{:text_only, reason}]}
    end
  end

  defp fallback_to_text_only(_config, skipped), do: {:error, :no_usable_option, skipped}

  defp resolve_text_only_fallback(option, config, skipped) do
    case ProviderPolicy.check(config.privacy, option) do
      :ok -> {:ok, option, skipped: Enum.reject(skipped, &(elem(&1, 0) == :text_only))}
      {:error, reason} -> {:error, :no_usable_option, skipped ++ [{:text_only, {:policy_refused, reason}}]}
    end
  end

  defp option_by_id(id, config) do
    case Registry.entry(id) do
      nil -> nil
      entry -> option(entry, config)
    end
  end

  defp option({id, module, fallback}, config) do
    descriptor = descriptor(id, module, fallback, config)

    case configuration_availability(id, module, config) do
      :ok -> option_after_configuration(module, descriptor, config)
      {:error, reason} -> Map.merge(descriptor, %{status: :unsupported, missing: [], reason: reason})
    end
  end

  defp option_after_configuration(module, descriptor, config) do
    case adapter_availability(module) do
      :ok -> credential_option(descriptor, config)
      {:error, reason} -> Map.merge(descriptor, %{status: :unsupported, missing: [], reason: reason})
    end
  end

  defp descriptor(:cascade, _module, fallback, config), do: cascade_descriptor(fallback, config, :cascade)
  defp descriptor(:text_only, _module, fallback, config), do: cascade_descriptor(fallback, config, :text_only)

  defp descriptor(_id, module, fallback, _config), do: Registry.descriptor(:adapter, module, fallback)

  defp cascade_descriptor(fallback, config, kind) do
    cascade = config.providers.cascade
    parts = %{stt: cascade.stt, llm: cascade.llm, tts: cascade.tts}

    case kind do
      :cascade ->
        Map.merge(fallback, %{needs: cascade_needs(cascade), parts: parts, client_parts: client_parts(cascade)})

      :text_only ->
        text_tts = if :browser_tts in cascade.tts, do: :browser_tts, else: :none

        Map.merge(fallback, %{
          needs: llm_needs(cascade.llm),
          parts: %{stt: :text_in, llm: cascade.llm, tts: text_tts},
          client_parts: [:text_in] ++ if(text_tts == :browser_tts, do: [:browser_tts], else: [])
        })
    end
  end

  defp configuration_availability(:codex_realtime, _module, %Config{providers: %{features: %{codex_realtime: true}}}),
    do: :ok

  defp configuration_availability(:codex_realtime, _module, _config), do: {:error, :feature_unavailable}

  defp configuration_availability(id, _module, %Config{providers: %{cascade: %{llm: nil}}})
       when id in [:cascade, :text_only],
       do: {:error, :cascade_not_configured}

  defp configuration_availability(_id, _module, _config), do: :ok

  defp adapter_availability(module),
    do: if(Registry.adapter_available?(module), do: :ok, else: {:error, :adapter_missing})

  defp credential_option(descriptor, config) do
    case missing_credentials(descriptor.needs, config) do
      [] ->
        Map.merge(descriptor, %{status: :ready, missing: [], reason: :ready})

      missing ->
        Map.merge(descriptor, %{status: :needs_credential, missing: missing, reason: {:missing_credential, hd(missing)}})
    end
  end

  defp missing_credentials(needs, %Config{credentials: credentials}) do
    Enum.reject(needs, fn provider ->
      credentials.fetch(provider, :probe) == {:ok, :present}
    end)
  end

  defp cascade_needs(cascade) do
    (llm_needs(cascade.llm) ++ Enum.flat_map(cascade.stt ++ cascade.tts, &List.wrap(Registry.credential_for_part(&1))))
    |> Enum.uniq()
  end

  defp llm_needs(llm) when is_binary(llm) do
    case String.split(llm, ":", parts: 2) do
      ["anthropic", _model] -> [:anthropic]
      ["gemini", _model] -> [:gemini]
      ["openai", _model] -> [:openai]
      _ -> []
    end
  end

  defp llm_needs(_llm), do: []

  defp client_parts(cascade) do
    Enum.filter(cascade.stt ++ cascade.tts, &(&1 in [:browser_stt, :browser_tts, :text_in]))
  end
end
