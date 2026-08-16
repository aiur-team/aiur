defmodule Aiur.Webhooks.IntervalPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.{IntervalPolicy, ModeRegistry}

  @base_ms 30_000
  @webhook_repo "aiur-team/webhook-repo"
  @polling_repo "aiur-team/polling-repo"

  defp start_registry(configured_repos) do
    name = :"interval_registry_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised({ModeRegistry, name: name, configured_repos: configured_repos, silence_threshold_ms: 900_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> :ok end})

    name
  end

  defp at(seconds), do: DateTime.add(~U[2026-08-09 12:00:00Z], seconds, :second)

  describe "a polling repo keeps today's interval, exactly" do
    test "a repo with no webhook is unaffected even by an aggressive widen factor" do
      registry = start_registry([])

      assert IntervalPolicy.poll_interval_ms(@base_ms, @polling_repo, server: registry, widen_factor: 10.0) == @base_ms
    end

    test "a configured but never-delivering repo is never widened" do
      registry = start_registry([@webhook_repo])

      assert ModeRegistry.transport(@webhook_repo, registry) == :polling
      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, server: registry, widen_factor: 4.0) == @base_ms
    end

    test "a degraded repo returns to the full-rate interval" do
      registry = start_registry([@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, server: registry, widen_factor: 4.0) == 120_000

      {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(901))

      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, server: registry, widen_factor: 4.0) == @base_ms
    end

    test "with no registry running everything polls at the base interval" do
      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, server: :no_such_registry, widen_factor: 8.0) == @base_ms
    end
  end

  describe "a proven repo may only ever be widened" do
    test "the widen factor applies once the repo is proven" do
      registry = start_registry([@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, server: registry, widen_factor: 2.5) == 75_000
    end

    test "the configured factor is read from settings" do
      registry = start_registry([@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      configured_factor = Aiur.Config.settings!().webhooks.poll_widen_factor

      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, server: registry) ==
               IntervalPolicy.widen(@base_ms, configured_factor)
    end

    test "a factor below 1.0 cannot shorten the interval" do
      assert IntervalPolicy.widen_factor(widen_factor: 0.25) == 1.0
      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, transport: :webhook, widen_factor: 0.25) == @base_ms
    end

    test "a nonsense factor falls back to no widening" do
      assert IntervalPolicy.widen_factor(widen_factor: "fast") == 1.0
      assert IntervalPolicy.widen_factor(widen_factor: nil) == 1.0
    end

    test "an integer factor is accepted" do
      assert IntervalPolicy.poll_interval_ms(@base_ms, @webhook_repo, transport: :webhook, widen_factor: 3) == 90_000
    end
  end
end
