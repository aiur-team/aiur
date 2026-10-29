defmodule Aiur.VoiceConverse.Host.CapabilityTest do
  use ExUnit.Case, async: true
  alias Aiur.VoiceConverse.Host.Capability

  defmodule Credentials do
    def fetch(:elevenlabs, :probe), do: {:ok, :present}
    def fetch(_provider, :probe), do: {:error, :missing}
  end

  test "capability exposes core selection and missing credential names without secrets" do
    assert {:ok, settings} = Aiur.Config.Schema.parse(%{"voice" => %{"conversation" => %{"providers" => %{"preference" => ["openai_realtime", "elevenlabs_agents"]}}}})
    context = %{run_shape: %{http_listener: true}, settings: settings}

    resolve = fn config ->
      VoiceConverse.Providers.resolve(%{config | credentials: Credentials})
    end

    result = Capability.evaluate(context, http_port_fun: fn -> 4000 end, availability_fun: fn -> :ok end, running_fun: fn -> true end, resolve_fun: resolve)
    assert result.state == :available
    assert result.preferred_provider == :elevenlabs_agents
    assert result.detail == "OpenAI Realtime skipped: OPENAI_API_KEY missing"
  end

  test "ElevenLabs missing reason includes both host credential names" do
    assert {:ok, config} = Aiur.VoiceConverse.Host.Config.build(%Aiur.Config.Schema.VoiceConversation{}, "/unused/voice")
    result = Capability.resolution_detail(config, {:error, :no_usable_option, [{:elevenlabs_agents, {:missing_credential, :elevenlabs}}]})
    assert result.preferred_provider == nil
    assert result.detail == "ElevenLabs Agents skipped: elevenlabs.api_key / ELEVENLABS_API_KEY missing"
  end

  test "reports the conversation availability and dashboard prerequisites" do
    context = %{run_shape: %{http_listener: true}, settings: %{observability: %{dashboard_writable: true}}}
    opts = [http_port_fun: fn -> 4000 end, availability_fun: fn -> :ok end, running_fun: fn -> true end]
    assert Capability.evaluate(context, opts) == %{state: :available}
    assert Capability.evaluate(context, Keyword.put(opts, :running_fun, fn -> false end)) == %{state: :unavailable, reason: :not_running}

    assert Capability.evaluate(context, Keyword.put(opts, :availability_fun, fn -> {:unavailable, :missing_credentials} end)) ==
             %{state: :unavailable, reason: :missing_credentials}

    assert Capability.evaluate(put_in(context.settings.observability.dashboard_writable, false), opts) == %{state: :unavailable, reason: :disabled}

    assert Capability.evaluate(context, Keyword.put(opts, :http_port_fun, fn -> nil end)) ==
             %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["api.http"]}
  end
end
