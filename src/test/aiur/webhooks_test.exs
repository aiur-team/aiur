defmodule Aiur.WebhooksTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks
  alias Aiur.Webhooks.ModeRegistry

  @repo "aiur-team/aiur"

  defp start_registry(configured_repos) do
    name = :"facade_registry_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised({ModeRegistry, name: name, configured_repos: configured_repos, silence_threshold_ms: 900_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> :ok end})

    name
  end

  describe "with no registry running the world looks exactly like today" do
    test "every repo reads as an unconfigured polling repo" do
      opts = [server: :no_registry_here]

      assert Webhooks.transport(@repo, opts) == :polling
      refute Webhooks.webhook_backed?(@repo, opts)
      assert Webhooks.polling_reason(@repo, opts) == :never_configured
      assert Webhooks.mode(@repo, opts).repo == @repo
      assert Webhooks.list(opts) == []
    end

    test "recording a delivery is a silent no-op rather than a crash" do
      assert Webhooks.record_delivery(@repo, server: :no_registry_here) == :ok
      assert Webhooks.transport(@repo, server: :no_registry_here) == :polling
    end
  end

  describe "with a registry running" do
    test "a delivery flips the facade to webhook mode" do
      registry = start_registry([@repo])
      assert Webhooks.transport(@repo, server: registry) == :polling
      assert Webhooks.polling_reason(@repo, server: registry) == :configured_unproven

      assert Webhooks.record_delivery(@repo, server: registry) == :ok

      assert Webhooks.transport(@repo, server: registry) == :webhook
      assert Webhooks.webhook_backed?(@repo, server: registry)
      assert Webhooks.polling_reason(@repo, server: registry) == nil
    end

    test "list/1 surfaces every known repo" do
      registry = start_registry([@repo, "aiur-team/other"])

      assert ["aiur-team/aiur", "aiur-team/other"] = registry |> then(&Webhooks.list(server: &1)) |> Enum.map(& &1.repo)
    end
  end
end
