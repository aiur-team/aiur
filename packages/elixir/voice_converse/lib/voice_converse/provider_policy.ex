defmodule VoiceConverse.ProviderPolicy do
  @moduledoc """
  Host-level provider policy, read from `Config.privacy`.

  A host serving a privacy-restricted audience can limit which providers a session may use and
  require each provider's no-logging or zero-retention options:

      privacy: %{
        provider_allowlist: [:openai_realtime, :elevenlabs_agents],
        required_provider_options: %{
          openai_realtime: %{store: false},
          elevenlabs_agents: %{record_voice: false}
        }
      }

  Both keys only tighten. With neither set (the default, `privacy: %{}`) every provider is
  allowed with whatever options it carries. An empty allowlist allows no provider. A provider
  with no `required_provider_options` entry has no required options.

  A session checks its provider with `check/2` before connecting and refuses to start on
  `{:error, reason}`.
  """

  @type provider_id :: atom()
  @type descriptor :: %{required(:id) => provider_id(), optional(:options) => map()}
  @type reason ::
          %{reason: :provider_not_allowed, provider: provider_id(), allowed: [provider_id()]}
          | %{
              reason: :required_option_unmet,
              provider: provider_id(),
              option: atom(),
              expected: term(),
              actual: {:ok, term()} | :missing
            }

  @doc "Validates the policy keys of a `privacy` map."
  @spec validate(map()) :: :ok | {:error, %{field: :privacy, reason: :invalid, key: atom()}}
  def validate(privacy) when is_map(privacy) do
    cond do
      not valid_allowlist?(Map.get(privacy, :provider_allowlist)) -> invalid(:provider_allowlist)
      not valid_required?(Map.get(privacy, :required_provider_options, %{})) -> invalid(:required_provider_options)
      true -> :ok
    end
  end

  def validate(_privacy), do: invalid(:privacy)

  @doc "Returns `:ok` when the provider meets the host policy, else the reason the session is refused."
  @spec check(map(), descriptor()) :: :ok | {:error, reason()}
  def check(privacy, %{id: id} = descriptor) when is_map(privacy) and is_atom(id) do
    with :ok <- check_allowed(Map.get(privacy, :provider_allowlist), id) do
      required = privacy |> Map.get(:required_provider_options, %{}) |> Map.get(id, %{})
      check_options(required, id, Map.get(descriptor, :options, %{}))
    end
  end

  defp check_allowed(nil, _id), do: :ok

  defp check_allowed(allowed, id) do
    if id in allowed,
      do: :ok,
      else: {:error, %{reason: :provider_not_allowed, provider: id, allowed: allowed}}
  end

  defp check_options(required, id, options) do
    required
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, expected} ->
      actual = Map.fetch(options, key)

      if actual != {:ok, expected} do
        actual = if actual == :error, do: :missing, else: actual
        {:error, %{reason: :required_option_unmet, provider: id, option: key, expected: expected, actual: actual}}
      end
    end)
  end

  defp valid_allowlist?(nil), do: true
  defp valid_allowlist?(list), do: is_list(list) and Enum.all?(list, &is_atom/1)

  defp valid_required?(required) when is_map(required) do
    Enum.all?(required, fn {id, opts} ->
      is_atom(id) and is_map(opts) and Enum.all?(Map.keys(opts), &is_atom/1)
    end)
  end

  defp valid_required?(_), do: false

  defp invalid(key), do: {:error, %{field: :privacy, reason: :invalid, key: key}}
end
