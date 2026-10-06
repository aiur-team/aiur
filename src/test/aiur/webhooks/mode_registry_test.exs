defmodule Aiur.Webhooks.ModeRegistryTest do
  use ExUnit.Case, async: true

  alias Aiur.Webhooks.{DeliveryMode, ModeRegistry}

  @webhook_repo "aiur-team/webhook-repo"
  @polling_repo "aiur-team/polling-repo"

  defp start_registry(opts) do
    test = self()

    name = :"mode_registry_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      silence_threshold_ms: 900_000,
      sweep_interval_ms: 3_600_000,
      alert_fun: fn alert_name, message, alert_opts ->
        send(test, {:alert, alert_name, message, alert_opts})
        :ok
      end
    ]

    {:ok, _pid} = start_supervised({ModeRegistry, Keyword.merge(defaults, opts)})
    name
  end

  defp at(seconds), do: DateTime.add(~U[2026-08-09 12:00:00Z], seconds, :second)

  defp ensure_pubsub! do
    unless Process.whereis(Aiur.PubSub) do
      {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
      start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    end

    :ok
  end

  describe "mode is per repo" do
    test "two tracked repos hold different modes at the same time" do
      registry = start_registry(configured_repos: [@webhook_repo])

      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      assert ModeRegistry.transport(@webhook_repo, registry) == :webhook
      assert ModeRegistry.transport(@polling_repo, registry) == :polling
      assert ModeRegistry.polling_reason_for(@polling_repo, registry) == :never_configured
    end

    test "an unknown repo reads back as a never-configured polling repo" do
      registry = start_registry([])

      mode = ModeRegistry.mode("aiur-team/never-heard-of-it", registry)

      assert mode.state == :never_configured
      assert DeliveryMode.transport(mode) == :polling
      assert ModeRegistry.list(registry) == []
    end

    test "configured repos are seeded unproven, never webhook-backed" do
      registry = start_registry(configured_repos: [@webhook_repo, @polling_repo])

      assert [first, second] = ModeRegistry.list(registry)
      assert first.repo == @polling_repo
      assert second.repo == @webhook_repo
      assert Enum.all?([first, second], &(&1.state == :configured_unproven))
      assert Enum.all?([first, second], &(DeliveryMode.transport(&1) == :polling))
    end

    test "blank and non-string configured repo entries are dropped" do
      registry = start_registry(configured_repos: ["  ", "", nil, " aiur-team/aiur "])

      assert [%DeliveryMode{repo: "aiur-team/aiur"}] = ModeRegistry.list(registry)
    end

    test "configure/3 can mark a repo expected without proving it" do
      registry = start_registry([])

      {:ok, mode} = ModeRegistry.configure(@webhook_repo, true, registry)

      assert mode.state == :configured_unproven
      assert ModeRegistry.transport(@webhook_repo, registry) == :polling
    end
  end

  describe "degradation and recovery" do
    test "silence corroborated by observed activity degrades the repo and alerts naming it" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))

      assert {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802))

      assert_received {:alert, "webhook.degraded", message, opts}
      assert message =~ @webhook_repo
      assert opts[:needs_attention] == true
      assert opts[:reason] =~ @webhook_repo

      assert opts[:reason] =~ "1 verified delivery",
             "the alert must carry the evidence that justified it, not a blanket guess at the cause"

      assert ModeRegistry.transport(@webhook_repo, registry) == :polling
      assert ModeRegistry.polling_reason_for(@webhook_repo, registry) == :degraded_from_silence
    end

    test "a silent but unproven repo never alerts" do
      registry = start_registry(configured_repos: [@webhook_repo])

      assert {:ok, []} = ModeRegistry.sweep(registry, at(100_000))
      refute_received {:alert, _name, _message, _opts}
    end

    test "the degradation alert fires once, not every sweep" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))

      {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802))
      assert_received {:alert, "webhook.degraded", _message, _opts}

      assert {:ok, []} = ModeRegistry.sweep(registry, at(3000))
      refute_received {:alert, "webhook.degraded", _message, _opts}
    end

    test "a resumed delivery restores webhook mode with no operator action" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))
      {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802))
      assert_received {:alert, "webhook.degraded", _message, _opts}

      {:ok, recovered} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(2000))

      assert recovered.state == :webhook_backed
      assert ModeRegistry.transport(@webhook_repo, registry) == :webhook

      assert_received {:alert, "webhook.recovered", message, opts}
      assert message =~ @webhook_repo
      assert opts[:needs_attention] == false
    end

    # Finding #1 (recovery edge): the `:degraded` broadcast must repeat on every
    # sweep while the repo stays degraded, so a gap-based source keeps a coarse
    # re-list for the whole outage instead of freezing after the one broadcast
    # that detected it.
    test "the degraded broadcast repeats while the repo stays degraded" do
      ensure_pubsub!()
      assert :ok = ModeRegistry.subscribe()
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))

      {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802))
      assert_received {:webhook_degraded, @webhook_repo}

      # Still degraded: the next sweep re-publishes the gap signal, so a source
      # that subscribed after the first broadcast still re-lists.
      {:ok, []} = ModeRegistry.sweep(registry, at(3000))
      assert_received {:webhook_degraded, @webhook_repo}
    end

    # Finding #1 (trailing edge): recovery must publish a signal too, so a
    # projection that rode the event stream through the degraded window re-lists
    # once the gap has closed — otherwise everything that changed during the
    # outage is lost permanently.
    test "a resumed delivery publishes the trailing-edge recovered broadcast" do
      ensure_pubsub!()
      assert :ok = ModeRegistry.subscribe_recovered()
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))
      {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802))
      assert_received {:alert, "webhook.degraded", _message, _opts}

      {:ok, _recovered} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(2000))

      assert_received {:webhook_recovered, @webhook_repo}
    end

    test "one repo degrading leaves its neighbours alone" do
      other = "aiur-team/other-repo"
      registry = start_registry(configured_repos: [@webhook_repo, other])

      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))
      {:ok, _mode} = ModeRegistry.record_delivery(other, server: registry, at: at(1790))

      assert {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802))
      assert ModeRegistry.transport(other, registry) == :webhook
    end

    test "an alert sink that raises cannot take the registry down" do
      name = :"mode_registry_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        start_supervised(
          {ModeRegistry, name: name, configured_repos: [@webhook_repo], silence_threshold_ms: 1_000, sweep_interval_ms: 3_600_000, alert_fun: fn _name, _message, _opts -> raise "alert sink down" end}
        )

      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: name, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: name, at: at(5))

      assert {:ok, [@webhook_repo]} = ModeRegistry.sweep(name, at(10))
      assert Process.alive?(pid)
      assert ModeRegistry.transport(@webhook_repo, name) == :polling
    end
  end

  describe "repository names are case-insensitive" do
    test "a delivery and its poller activity reach the same entry despite differing case" do
      registry = start_registry(configured_repos: ["aiur-team/Aiur"])

      {:ok, _mode} = ModeRegistry.record_delivery("AIUR-TEAM/aiur", server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity("aiur-team/AIUR", server: registry, at: at(901))

      assert [mode] = ModeRegistry.list(registry),
             "one repository must never become two entries that fail in opposite directions"

      assert mode.delivery_count == 1
      assert mode.last_activity_at == at(901)

      assert {:ok, ["aiur-team/aiur"]} = ModeRegistry.sweep(registry, at(1802))
      assert_received {:alert, "webhook.degraded", _message, _opts}
    end

    # The reviewer's scenario exactly: deliveries arrive under the payload's
    # case while config and the poller use their own. Split across two entries,
    # the config-cased one has activity and zero deliveries and raises a false
    # never_delivered about a webhook that is working perfectly.
    test "a configured repo proven under different case never raises never_delivered" do
      registry = start_registry(configured_repos: ["aiur-team/Aiur"])

      {:ok, _mode} = ModeRegistry.record_delivery("aiur-team/aiur", server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_activity("aiur-team/Aiur", server: registry, at: at(50))

      {:ok, []} = ModeRegistry.sweep(registry, at(100))

      refute_received {:alert, "webhook.never_delivered", _message, _opts}
    end

    test "reads answer under any case" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      assert ModeRegistry.transport("AIUR-TEAM/WEBHOOK-REPO", registry) == :webhook
    end
  end

  describe "activity corroborates a mode without creating one" do
    test "activity for a repo the registry has never heard of adds no row" do
      registry = start_registry(configured_repos: [@webhook_repo])

      {:ok, _mode} = ModeRegistry.record_activity("aiur-team/stranger", server: registry, at: at(50))

      assert [%DeliveryMode{repo: @webhook_repo}] = ModeRegistry.list(registry),
             "the publish path offers activity for every polled resource; minting rows from it fills the CLI table with entries that can never alert"
    end

    test "a repo proven by delivery alone still accepts activity" do
      registry = start_registry([])

      {:ok, _mode} = ModeRegistry.record_delivery("aiur-team/unlisted", server: registry, at: at(0))
      {:ok, mode} = ModeRegistry.record_activity("aiur-team/unlisted", server: registry, at: at(901))

      assert mode.last_activity_at == at(901)
    end
  end

  describe "a re-offered observation is a replay, not evidence" do
    test "the same observation counts once however often it is offered" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901), observation: {:issue_comment, "aiur-team", "webhook-repo", "7"})

      {:ok, mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(5000), observation: {:issue_comment, "aiur-team", "webhook-repo", "7"})

      assert mode.last_activity_at == at(901),
             "the poller re-offers the same resource every sweep by design; counting the repeats degrades an idle repo"
    end

    test "a genuinely different observation still counts" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901), observation: {:issue_comment, "aiur-team", "webhook-repo", "7"})

      {:ok, mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(950), observation: {:issue_comment, "aiur-team", "webhook-repo", "8"})

      assert mode.last_activity_at == at(950)
    end

    test "an observation with no identity always counts" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901))
      {:ok, mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(950))

      assert mode.last_activity_at == at(950)
    end

    test "the same resource under two repos is two observations" do
      other = "aiur-team/other-repo"
      registry = start_registry(configured_repos: [@webhook_repo, other])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))
      {:ok, _mode} = ModeRegistry.record_delivery(other, server: registry, at: at(0))

      observation = {:issue_comment, "aiur-team", "webhook-repo", "7"}
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901), observation: observation)
      {:ok, mode} = ModeRegistry.record_activity(other, server: registry, at: at(901), observation: observation)

      assert mode.last_activity_at == at(901)
    end

    test "a repo that keeps being re-offered still degrades on its first sighting" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(901), observation: {:issue_comment, "aiur-team", "webhook-repo", "7"})

      assert {:ok, [@webhook_repo]} = ModeRegistry.sweep(registry, at(1802)),
             "deduplicating replays must not blunt detection of a genuinely dead tunnel"
    end
  end

  describe "the asynchronous activity path" do
    test "a cast records activity just as a call does" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      :ok = ModeRegistry.record_activity_async(@webhook_repo, server: registry, at: at(901))

      # `mode/2` is a call to the same process, so it cannot answer until the
      # cast ahead of it has been handled.
      assert ModeRegistry.mode(@webhook_repo, registry).last_activity_at == at(901)
    end

    test "a cast never moves activity backwards" do
      registry = start_registry(configured_repos: [@webhook_repo])

      :ok = ModeRegistry.record_activity_async(@webhook_repo, server: registry, at: at(901))
      :ok = ModeRegistry.record_activity_async(@webhook_repo, server: registry, at: at(10))

      assert ModeRegistry.mode(@webhook_repo, registry).last_activity_at == at(901)
    end
  end

  describe "an idle repository raises nothing" do
    test "a proven repo with no observed activity never degrades however long it is silent" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: at(0))

      assert {:ok, []} = ModeRegistry.sweep(registry, at(100_000))
      refute_received {:alert, "webhook.degraded", _message, _opts}
      assert ModeRegistry.transport(@webhook_repo, registry) == :webhook
    end
  end

  describe "configured but never delivered" do
    test "observed activity with no delivery ever raises its own alert" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(50))

      assert {:ok, []} = ModeRegistry.sweep(registry, at(901))

      assert_received {:alert, "webhook.never_delivered", message, opts}
      assert message =~ @webhook_repo
      assert message =~ "never delivered"
      assert opts[:needs_attention] == true
      assert opts[:reason] =~ "reachable from the public internet"

      refute_received {:alert, "webhook.degraded", _message, _opts}
    end

    test "the never-delivered alert fires once, not every sweep" do
      registry = start_registry(configured_repos: [@webhook_repo])
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(50))

      {:ok, []} = ModeRegistry.sweep(registry, at(901))
      assert_received {:alert, "webhook.never_delivered", _message, _opts}

      {:ok, []} = ModeRegistry.sweep(registry, at(5000))
      refute_received {:alert, "webhook.never_delivered", _message, _opts}
    end

    test "recording activity never promotes a repo to webhook mode" do
      registry = start_registry(configured_repos: [@webhook_repo])

      {:ok, mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: at(50))

      assert mode.state == :configured_unproven
      assert ModeRegistry.transport(@webhook_repo, registry) == :polling
    end
  end

  describe "the timer sweep" do
    test "the scheduled sweep degrades without an explicit call" do
      registry =
        start_registry(
          configured_repos: [@webhook_repo],
          silence_threshold_ms: 1,
          sweep_interval_ms: 10
        )

      {:ok, _mode} = ModeRegistry.record_delivery(@webhook_repo, server: registry, at: DateTime.add(DateTime.utc_now(), -60, :second))
      {:ok, _mode} = ModeRegistry.record_activity(@webhook_repo, server: registry, at: DateTime.utc_now())

      assert_receive {:alert, "webhook.degraded", _message, _opts}, 1_000
      assert ModeRegistry.transport(@webhook_repo, registry) == :polling
    end
  end

  describe "settings" do
    test "seconds from settings become the millisecond threshold" do
      registry =
        start_registry(
          settings: %Aiur.Config.Schema.Webhooks{repos: [@webhook_repo], silence_threshold_seconds: 42, sweep_interval_seconds: 3_600},
          silence_threshold_ms: nil,
          sweep_interval_ms: nil
        )

      assert ModeRegistry.silence_threshold_ms(registry) == 42_000
      assert [%DeliveryMode{repo: @webhook_repo, state: :configured_unproven}] = ModeRegistry.list(registry)
    end
  end
end
