defmodule Aiur.VoiceConverse.Host.Capability do
  @moduledoc "Reports whether the host can offer voice conversation."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ["voice.conversation"]

  @impl true
  def capabilities(context), do: %{"voice.conversation" => evaluate(context)}

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    cond do
      Provider.http(context, opts).state != :available -> Provider.dependency("api.http")
      context.settings == :unavailable -> %{state: :unknown, reason: :unknown}
      Provider.writable(context) == false -> %{state: :unavailable, reason: :disabled}
      Provider.writable(context) == :unknown -> %{state: :unknown, reason: :unknown}
      true -> context |> provider_details(availability(Keyword.get(opts, :availability_fun, &Aiur.VoiceConversation.availability/0).(), opts), opts)
    end
  end

  defp provider_details(%{settings: %{voice: %{conversation: settings}}}, status, opts) do
    case Aiur.VoiceConverse.Host.Config.build(settings, "/unused/capability") do
      {:ok, config} ->
        resolution = Keyword.get(opts, :resolve_fun, &VoiceConverse.Providers.resolve/1).(config)
        details = resolution_detail(config, resolution)
        Map.merge(status, details)

      {:error, _reason} ->
        status
    end
  end

  defp provider_details(_context, status, _opts), do: status

  @doc false
  @spec resolution_detail(VoiceConverse.Config.t(), tuple()) :: map()
  def resolution_detail(config, {:ok, option, skipped: skipped}) do
    %{preferred_provider: option.id, preference_state: :available, provider_reason: render_skipped(config, skipped)}
  end

  def resolution_detail(config, {:error, :no_usable_option, skipped}) do
    %{preferred_provider: nil, preference_state: :unavailable, provider_reason: render_skipped(config, skipped)}
  end

  defp render_skipped(config, skipped) do
    options = Enum.map(VoiceConverse.Providers.Registry.entries(), fn {id, module, fallback} -> VoiceConverse.Providers.Registry.descriptor(id, module, fallback) end)

    Enum.map_join(skipped, "; ", fn {id, reason} ->
      label =
        case Enum.find(options, &(&1.id == id)) do
          nil -> to_string(id)
          option -> option.label
        end

      "#{label} skipped: #{skip_reason(config, reason)}"
    end)
  end

  defp skip_reason(config, {:missing_credential, provider}) do
    name = Map.get(config.credential_names, provider, VoiceConverse.Providers.credential_env(provider))
    "#{name} missing"
  end

  defp skip_reason(_config, reason), do: inspect(reason)

  defp availability(:ok, opts) do
    if Keyword.get(opts, :running_fun, fn -> Process.whereis(Aiur.VoiceConversation.instance()) != nil end).(),
      do: %{state: :available},
      else: %{state: :unavailable, reason: :not_running}
  end

  defp availability({:unavailable, {reason, field}}, _opts), do: %{state: :unavailable, reason: reason, detail: to_string(field)}
  defp availability({:unavailable, reason}, _opts), do: %{state: :unavailable, reason: reason}
end
