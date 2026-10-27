defmodule VoiceConverse.ProviderPolicy do
  @moduledoc """
  Host-level provider policy, read from `Config.privacy`.

  A host serving a privacy-restricted audience can limit which providers a session may use and
  require each provider's no-logging or zero-retention options, and restrict configured provider
  base URLs to known hosts:

      privacy: %{
        provider_allowlist: [:openai_realtime, :elevenlabs_agents],
        required_provider_options: %{
          openai_realtime: %{store: false},
          elevenlabs_agents: %{record_voice: false}
        },
        provider_host_allowlist: ["speech.internal"]
      }

  `check/2` takes the provider's registry descriptor (`VoiceConverse.Provider.descriptor/0`) and
  matches `required_provider_options` against the descriptor's `:privacy` map, where an adapter
  declares its storage and retention facts (`store: false`, `record_voice: false`, ...).

  All three keys only tighten. With none set (the default, `privacy: %{}`) every provider is
  allowed whatever its privacy facts. An empty allowlist allows no provider. A provider
  with no `required_provider_options` entry has no required options.

  When `provider_host_allowlist` is set, every URL in the descriptor's `:base_urls` must use an
  HTTP(S) host on that exact allowlist. A missing or malformed base URL fails closed. Ports and
  paths do not affect the host comparison.

  Validation is closed: an unknown `privacy` key (say, a misspelled `provider_allow_list`) is
  invalid rather than ignored, so a typo cannot silently allow every provider. With an allowlist
  set, a `required_provider_options` entry for a provider not on it is invalid too.

  Required options are a flat map of key to exact value, compared with `===` (`0` does not
  satisfy `0.0`). A descriptor's `:privacy` map must therefore be flat: an adapter whose provider
  nests the setting (ElevenLabs `platform_settings.privacy.record_voice`) declares it as
  `record_voice` in its descriptor.

  A session checks its provider with `check/2` before connecting and refuses to start on
  `{:error, reason}`.
  """

  @known_keys [:provider_allowlist, :required_provider_options, :provider_host_allowlist]

  @type provider_id :: atom()
  @typedoc "The subset of `VoiceConverse.Provider.descriptor/0` this module reads."
  @type descriptor :: %{
          required(:id) => provider_id(),
          optional(:privacy) => map(),
          optional(:base_urls) => [String.t()],
          optional(atom()) => term()
        }
  @type reason ::
          %{reason: :provider_not_allowed, provider: provider_id(), allowed: [provider_id()]}
          | %{
              reason: :required_option_unmet,
              provider: provider_id(),
              option: atom(),
              expected: term(),
              actual: {:ok, term()} | :missing
            }
          | %{reason: :provider_host_missing, provider: provider_id(), allowed: [String.t()]}
          | %{reason: :provider_host_invalid, provider: provider_id()}
          | %{reason: :provider_host_not_allowed, provider: provider_id(), host: String.t(), allowed: [String.t()]}

  @doc "Validates the policy keys of a `privacy` map."
  @spec validate(map()) :: :ok | {:error, %{field: :privacy, reason: :invalid, key: atom()}}
  def validate(privacy) when is_map(privacy) do
    allowlist = Map.get(privacy, :provider_allowlist)

    cond do
      unknown = Enum.find(Map.keys(privacy), &(&1 not in @known_keys)) ->
        invalid(unknown)

      not valid_allowlist?(allowlist) ->
        invalid(:provider_allowlist)

      not valid_required?(Map.get(privacy, :required_provider_options, %{}), allowlist) ->
        invalid(:required_provider_options)

      not valid_host_allowlist?(Map.get(privacy, :provider_host_allowlist)) ->
        invalid(:provider_host_allowlist)

      true ->
        :ok
    end
  end

  def validate(_privacy), do: invalid(:privacy)

  @doc "Returns `:ok` when the provider meets the host policy, else the reason the session is refused."
  @spec check(map(), descriptor()) :: :ok | {:error, reason()}
  def check(privacy, %{id: id} = descriptor) when is_map(privacy) and is_atom(id) do
    required = privacy |> Map.get(:required_provider_options, %{}) |> Map.get(id, %{})

    with :ok <- check_allowed(Map.get(privacy, :provider_allowlist), id),
         :ok <- check_options(required, id, Map.get(descriptor, :privacy, %{})) do
      check_hosts(Map.get(privacy, :provider_host_allowlist), id, Map.get(descriptor, :base_urls))
    end
  end

  defp check_allowed(nil, _id), do: :ok

  defp check_allowed(allowed, id) do
    if id in allowed,
      do: :ok,
      else: {:error, %{reason: :provider_not_allowed, provider: id, allowed: allowed}}
  end

  defp check_options(required, id, facts) do
    required
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, expected} ->
      actual = Map.fetch(facts, key)

      if actual !== {:ok, expected} do
        actual = if actual == :error, do: :missing, else: actual
        {:error, %{reason: :required_option_unmet, provider: id, option: key, expected: expected, actual: actual}}
      end
    end)
  end

  defp check_hosts(nil, _id, _base_urls), do: :ok

  defp check_hosts(allowed, id, base_urls) when base_urls in [nil, []],
    do: {:error, %{reason: :provider_host_missing, provider: id, allowed: allowed}}

  defp check_hosts(allowed, id, base_urls) when is_list(base_urls) do
    normalized = Enum.map(allowed, fn host -> host |> normalize_host() |> elem(1) end)

    Enum.reduce_while(base_urls, :ok, fn base_url, :ok ->
      case base_url_host(base_url) do
        {:ok, host} ->
          check_host(host, normalized, allowed, id)

        :error ->
          {:halt, {:error, %{reason: :provider_host_invalid, provider: id}}}
      end
    end)
  end

  defp check_hosts(_allowed, id, _base_urls), do: {:error, %{reason: :provider_host_invalid, provider: id}}

  defp check_host(host, normalized, allowed, id) do
    if host in normalized,
      do: {:cont, :ok},
      else: {:halt, {:error, %{reason: :provider_host_not_allowed, provider: id, host: host, allowed: allowed}}}
  end

  defp valid_allowlist?(nil), do: true
  defp valid_allowlist?(list), do: is_list(list) and Enum.all?(list, &is_atom/1)

  defp valid_required?(required, allowlist) when is_map(required) do
    Enum.all?(required, fn {id, opts} ->
      is_atom(id) and (allowlist == nil or id in allowlist) and is_map(opts) and Enum.all?(Map.keys(opts), &is_atom/1)
    end)
  end

  defp valid_required?(_required, _allowlist), do: false

  defp valid_host_allowlist?(nil), do: true

  defp valid_host_allowlist?(hosts) when is_list(hosts),
    do: Enum.all?(hosts, &match?({:ok, _host}, normalize_host(&1)))

  defp valid_host_allowlist?(_hosts), do: false

  defp normalize_host(host) when is_binary(host) do
    host = host |> String.trim() |> String.trim_trailing(".") |> String.downcase()

    case URI.new("https://" <> host) do
      {:ok, %URI{host: ^host, path: nil, query: nil, fragment: nil, userinfo: nil}} when host != "" -> {:ok, host}
      _ -> :error
    end
  end

  defp normalize_host(_host), do: :error

  defp base_url_host(base_url) when is_binary(base_url) do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, host |> String.trim_trailing(".") |> String.downcase()}

      _ ->
        :error
    end
  end

  defp base_url_host(_base_url), do: :error

  defp invalid(key), do: {:error, %{field: :privacy, reason: :invalid, key: key}}
end
