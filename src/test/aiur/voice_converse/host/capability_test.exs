defmodule Aiur.VoiceConverse.Host.CapabilityTest do
  use ExUnit.Case, async: true
  alias Aiur.VoiceConverse.Host.Capability

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
