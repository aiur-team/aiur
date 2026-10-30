defmodule Aiur.VoiceConverse.Host.CapabilityTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.VoiceConversation, as: Settings
  alias Aiur.VoiceConverse.Host.{Capability, Config}

  defmodule Credentials do
    def fetch(:elevenlabs, :probe), do: {:ok, :present}
    def fetch(_provider, :probe), do: {:error, :missing}
  end

  test "capability exposes core selection and missing credential names without secrets" do
    assert {:ok, settings} = Schema.parse(%{"voice" => %{"conversation" => %{"providers" => %{"preference" => ["openai_realtime", "elevenlabs_agents"]}}}})
    context = %{run_shape: %{http_listener: true}, settings: settings}

    resolve = fn config ->
      VoiceConverse.Providers.resolve(%{config | credentials: Credentials})
    end

    result = Capability.evaluate(context, http_port_fun: fn -> 4000 end, availability_fun: fn -> :ok end, running_fun: fn -> true end, resolve_fun: resolve)
    assert result.state == :available
    assert result.preferred_provider == :elevenlabs_agents
    assert result.preference_state == :available
    wire = Aiur.Capabilities.to_wire(%{capabilities: %{"voice.conversation" => result}})
    assert wire["capabilities"]["voice.conversation"]["preferred_provider"] == "elevenlabs_agents"
    assert wire["capabilities"]["voice.conversation"]["provider_reason"] == "OpenAI Realtime skipped: OPENAI_API_KEY missing"
    assert result.provider_reason == "OpenAI Realtime skipped: OPENAI_API_KEY missing"
    report = %{machine: nil, instance: nil, repository: nil, executor: nil, revision: 1, age_ms: 0, freshness: "current", capabilities: %{"voice.conversation" => result}}
    rendered = Aiur.CapabilitiesCLI.render(report)
    assert rendered =~ "preference=available preferred=elevenlabs_agents"
    assert rendered =~ result.provider_reason
  end

  test "ElevenLabs missing reason includes both host credential names" do
    assert {:ok, config} = Config.build(%Settings{}, "/unused/voice")
    result = Capability.resolution_detail(config, {:error, :no_usable_option, [{:elevenlabs_agents, {:missing_credential, :elevenlabs}}]})
    assert result.preferred_provider == nil
    assert result.preference_state == :unavailable
    assert result.provider_reason == "ElevenLabs Agents skipped: elevenlabs.api_key / ELEVENLABS_API_KEY missing"
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
