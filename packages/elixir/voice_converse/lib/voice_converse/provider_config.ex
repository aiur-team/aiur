defmodule VoiceConverse.ProviderConfig do
  @moduledoc false

  @default_preference [:elevenlabs_agents, :openai_live, :gemini_live, :cascade]
  @defaults %{
    preference: @default_preference,
    mode: :voice,
    cascade: %{stt: [:browser_stt], llm: nil, tts: [:browser_tts]},
    on_missing_credential: :next,
    features: %{codex_realtime: false}
  }
  @stt_parts [:browser_stt, :elevenlabs_stt, :openai_stt, :text_in]
  @tts_parts [:browser_tts, :elevenlabs_tts, :openai_tts, :none]

  @spec default() :: map()
  def default, do: @defaults

  @spec default_preference() :: [atom()]
  def default_preference, do: @default_preference

  @spec merge(map() | term()) :: map() | term()
  def merge(nil), do: @defaults

  def merge(providers) when is_map(providers) do
    @defaults
    |> Map.merge(Map.drop(providers, [:cascade, :features]))
    |> Map.put(:cascade, merge_nested(@defaults.cascade, Map.get(providers, :cascade, %{})))
    |> Map.put(:features, merge_nested(@defaults.features, Map.get(providers, :features, %{})))
  end

  def merge(providers), do: providers

  @spec validate(term()) :: :ok | {:error, %{field: :providers, reason: :invalid, key: atom()}}
  def validate(providers) when is_map(providers) do
    with :ok <- check_keys(providers, Map.keys(@defaults)),
         {:ok, preference} <- fetch(providers, :preference),
         :ok <- check_preference(preference),
         {:ok, mode} <- fetch(providers, :mode),
         :ok <- check_mode(mode),
         {:ok, policy} <- fetch(providers, :on_missing_credential),
         :ok <- check_policy(policy),
         {:ok, cascade} <- fetch(providers, :cascade),
         :ok <- check_cascade(cascade),
         {:ok, features} <- fetch(providers, :features),
         :ok <- check_features(features) do
      :ok
    end
  end

  def validate(_providers), do: invalid(:providers)

  defp merge_nested(default, value) when is_map(value), do: Map.merge(default, value)
  defp merge_nested(_default, value), do: value

  defp fetch(map, key), do: if(Map.has_key?(map, key), do: {:ok, Map.fetch!(map, key)}, else: invalid(key))

  defp check_keys(map, allowed) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> invalid(key)
    end
  end

  defp check_preference(value) when is_list(value) do
    if Enum.all?(value, &is_atom/1), do: :ok, else: invalid(:preference)
  end

  defp check_preference(_value), do: invalid(:preference)
  defp check_mode(mode) when mode in [:text, :voice], do: :ok
  defp check_mode(_mode), do: invalid(:mode)
  defp check_policy(policy) when policy in [:next, :refuse, :text_only], do: :ok
  defp check_policy(_policy), do: invalid(:on_missing_credential)

  defp check_cascade(cascade) when is_map(cascade) do
    with :ok <- check_keys(cascade, [:llm, :stt, :tts]),
         {:ok, stt} <- fetch(cascade, :stt),
         :ok <- check_parts(stt, @stt_parts, :stt),
         {:ok, llm} <- fetch(cascade, :llm),
         :ok <- check_llm(llm),
         {:ok, tts} <- fetch(cascade, :tts),
         :ok <- check_parts(tts, @tts_parts, :tts) do
      :ok
    end
  end

  defp check_cascade(_cascade), do: invalid(:cascade)

  defp check_parts(parts, allowed, key) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &(&1 in allowed)), do: :ok, else: invalid(key)
  end

  defp check_parts(_parts, _allowed, key), do: invalid(key)
  defp check_llm(nil), do: :ok

  defp check_llm(llm) when is_binary(llm) do
    case String.split(llm, ":", parts: 2) do
      [vendor, model] when vendor != "" and model != "" and vendor in ["anthropic", "gemini", "openai"] -> :ok
      _ -> invalid(:llm)
    end
  end

  defp check_llm(_llm), do: invalid(:llm)

  defp check_features(features) when is_map(features) do
    if Enum.all?(features, fn {_key, value} -> is_boolean(value) end), do: :ok, else: invalid(:features)
  end

  defp check_features(_features), do: invalid(:features)
  defp invalid(key), do: {:error, %{field: :providers, reason: :invalid, key: key}}
end
