defmodule Aiur.Capabilities.OptionalProvidersTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.CapabilityProvider, as: Orders
  alias Aiur.Claude.RemoteControl.CapabilityProvider, as: Remote
  alias Aiur.ElevenLabs.CapabilityProvider, as: Voice
  alias Aiur.LiveConversation.CapabilityProvider, as: Conversations
  alias Aiur.ProviderMeterProjection.CapabilityProvider, as: Meters
  alias Aiur.Webhooks.CapabilityProvider, as: Webhooks
  alias Aiur.Webhooks.DeliveryMode
  alias AiurWeb.StreamdeckCapabilityProvider, as: Deck

  @context %{
    run_shape: %{http_listener: true},
    settings: %{
      tracker: %{kind: "github", github: %{repo: "test-owner/optional-providers"}},
      elevenlabs: %{api_key: "secret-key", voice_id: "voice-id"},
      agent: %{remote_control: true, routing: %{}}
    }
  }
  @available %{state: :available}
  @unknown %{state: :unknown, reason: :unknown}
  @not_configured %{state: :unavailable, reason: :not_configured}
  @not_running %{state: :unavailable, reason: :not_running}
  @http_dependency %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["api.http"]}

  defp inputs(overrides \\ []) do
    Keyword.merge(
      [lookup_fun: fn _ -> self() end, http_port_fun: fn -> 4000 end, env_fun: fn _ -> "secret" end, catalog_fun: fn -> %{health: %{state: :healthy}, data: %{entries: [:root]}} end],
      overrides
    )
  end

  test "build orders are unsupported on Linear and progress depends on them" do
    context = put_in(@context.settings.tracker.kind, "linear")
    caps = Orders.evaluate(context, inputs(catalog_fun: fn -> flunk("must not read catalog") end))
    assert caps["build_orders"] == %{state: :unavailable, reason: :unsupported_tracker}
    assert caps["build_orders.progress"] == %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_orders"]}
  end

  test "healthy roots enable progress; no root is unavailable with no numeric fields" do
    assert Orders.evaluate(@context, inputs()) == %{"build_orders" => @available, "build_orders.progress" => @available}
    caps = Orders.evaluate(@context, inputs(catalog_fun: fn -> %{health: %{state: :healthy}, data: %{entries: []}} end))
    assert caps == %{"build_orders" => @available, "build_orders.progress" => @not_configured}
  end

  test "absent projection and degraded health never claim progress" do
    caps = Orders.evaluate(@context, inputs(lookup_fun: fn _ -> nil end))
    assert caps["build_orders"] == @not_running
    assert caps["build_orders.progress"].reason == :dependency_unavailable
    observed = ~U[2026-10-09 00:00:00Z]
    caps = Orders.evaluate(@context, inputs(catalog_fun: fn -> %{health: %{state: :stale, observed_at: observed}, data: %{entries: [:root]}} end))
    assert caps["build_orders"] == %{state: :degraded, reason: :unknown, observed_at: observed}
    assert caps["build_orders.progress"].reason == :dependency_unavailable
  end

  test "unknown catalog data cannot become absent progress" do
    caps = Orders.evaluate(@context, inputs(catalog_fun: fn -> %{health: %{state: :healthy}, data: nil} end))
    assert caps["build_orders.progress"] == @unknown
  end

  test "unreadable config stays unknown for config-derived IDs" do
    context = %{@context | settings: :unavailable}

    for {provider, ids} <- [{Orders, ~w(build_orders)}, {Voice, ~w(voice.stt voice.tts)}, {Remote, ~w(remote_control)}, {Webhooks, ~w(webhook_ingress)}] do
      caps = provider.evaluate(context, inputs())
      for id <- ids, do: assert(caps[id] == @unknown)
    end
  end

  test "voice key and voice ID are checked separately and secrets never leave providers" do
    assert Voice.evaluate(@context, inputs()) == %{"voice.stt" => @available, "voice.tts" => @available}

    for value <- [nil, "", "  "] do
      context = put_in(@context.settings.elevenlabs.api_key, value)
      assert Voice.evaluate(context, inputs()) == %{"voice.stt" => @not_configured, "voice.tts" => @not_configured}
      context = put_in(@context.settings.elevenlabs.voice_id, value)
      assert Voice.evaluate(context, inputs()) == %{"voice.stt" => @available, "voice.tts" => @not_configured}
    end

    refute inspect(Voice.evaluate(@context, inputs())) =~ "secret-key"
  end

  test "HTTP-dependent optional IDs require a bound listener in either run shape" do
    for shape <- [true, false], provider <- [Voice, Deck, Remote, Conversations] do
      context = put_in(@context.run_shape.http_listener, shape)
      caps = provider.evaluate(context, inputs(http_port_fun: fn -> nil end))
      for {_id, entry} <- caps, do: assert(entry == @http_dependency)
    end
  end

  test "Stream Deck requires both nonblank dashboard credentials" do
    assert Deck.evaluate(@context, inputs())["streamdeck"] == @available

    for missing <- ~w(AIUR_DASHBOARD_USERNAME AIUR_DASHBOARD_PASSWORD), blank <- [nil, "", " "] do
      env = fn name -> if name == missing, do: blank, else: "secret" end
      assert Deck.evaluate(@context, inputs(env_fun: env))["streamdeck"] == @not_configured
    end
  end

  for {mode, expected} <- [
        {nil, %{state: :unavailable, reason: :not_configured}},
        {:never_configured, %{state: :unavailable, reason: :not_configured}},
        {:configured_unproven, %{state: :degraded, reason: :unknown}},
        {:degraded, %{state: :degraded, reason: :not_running}},
        {:webhook_backed, %{state: :available}},
        {:unexpected, %{state: :unknown, reason: :unknown}}
      ] do
    test "webhook ingress maps #{inspect(mode)} without guessing delivery" do
      mode = unquote(mode)
      reader = fn "test-owner/optional-providers" -> if mode, do: %DeliveryMode{repo: "test-owner/optional-providers", state: mode}, else: nil end
      assert Webhooks.evaluate(@context, mode_fun: reader)["webhook_ingress"] == unquote(Macro.escape(expected))
    end
  end

  test "non-GitHub webhook ingress is not configured" do
    assert Webhooks.evaluate(put_in(@context.settings.tracker.kind, "linear"))["webhook_ingress"] == @not_configured
  end

  test "Remote Control is enabled by configuration or remote routes; disabled wins over HTTP" do
    assert Remote.evaluate(@context, inputs())["remote_control"] == @available
    context = put_in(@context.settings.agent.remote_control, false)
    assert Remote.evaluate(context, inputs(http_port_fun: fn -> nil end))["remote_control"] == %{state: :unavailable, reason: :disabled}
    context = put_in(context.settings.agent.routing, %{"default" => "claude:haiku+remote"})
    assert Remote.evaluate(context, inputs())["remote_control"] == @available
  end

  test "meters require the projection and at least one nonblank provider key" do
    assert Meters.evaluate(@context, inputs(lookup_fun: fn _ -> nil end))["accounting.meters"] == @not_running

    for blank <- [nil, "", " "] do
      assert Meters.evaluate(@context, inputs(env_fun: fn _ -> blank end))["accounting.meters"] == @not_configured
    end

    for key <- ~w(MOONSHOT_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY OPENROUTER_MANAGEMENT_KEY) do
      env = fn name -> if name == key, do: "secret", else: nil end
      assert Meters.evaluate(@context, inputs(env_fun: env))["accounting.meters"] == @available
    end
  end

  test "conversations remain degraded with disk history when the live process is absent" do
    assert Conversations.evaluate(@context, inputs())["conversations.read"] == @available
    assert Conversations.evaluate(@context, inputs(lookup_fun: fn _ -> nil end))["conversations.read"] == %{state: :degraded, reason: :not_running}
  end
end
