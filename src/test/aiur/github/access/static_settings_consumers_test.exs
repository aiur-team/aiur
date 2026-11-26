defmodule Aiur.GitHub.Access.StaticSettingsConsumersTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Access.{Settings, StaticSettings}
  alias Aiur.GitHub.{BrokerTimeout, Budget, CredentialHeadroom, Quota, ResourceEvents, ResourceStore, Transport}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    keys = [:github_access_settings_provider, :github_access_settings, :github_request_deadline_ms]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})
    on_exit(fn -> Aiur.TestSupport.restore_app_env(previous) end)
    Application.put_env(:aiur, :github_access_settings_provider, StaticSettings)
    Application.delete_env(:aiur, :github_request_deadline_ms)
    configure(root)
    %{root: root}
  end

  test "quota recovery wakes the target from static settings", %{root: root} do
    configure(root, recovery_target: self())
    quota = start_quota(root)

    observe(quota, 500)
    assert {:hold, %{resource: "core", remaining: 500}} = Quota.dispatch_status(quota)
    refute_receive :github_quota_recovered, 10

    observe(quota, 4_500)
    assert Quota.dispatch_status(quota) == :available
    assert_receive :github_quota_recovered, 1_000
  end

  # Future regression guard: no configured target remains a valid standalone setting.
  test "an unset recovery target leaves recovery available without a notification", %{root: root} do
    quota = start_quota(root)
    observe(quota, 500)
    assert {:hold, %{resource: "core"}} = Quota.dispatch_status(quota)

    observe(quota, 4_500)
    assert Quota.dispatch_status(quota) == :available
    refute_receive :github_quota_recovered, 10
  end

  test "only the configured poll owner gets the shorter request deadline", %{root: root} do
    configure(root, poll_owner: self())
    assert Transport.request_deadline_ms(%{}) == 10_000

    configure(root)
    assert Transport.request_deadline_ms(%{}) == 60_000
  end

  test "a store deposit reaches subscribers through the configured PubSub", %{root: root} do
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    configure(root, pubsub: pubsub)

    unless Process.whereis(ResourceStore), do: start_supervised!({ResourceStore, path: Path.join(root, "resources.json")})
    key = ResourceStore.key(:issue_comment, "settings", "ports", System.unique_integer([:positive]))
    on_exit(fn -> ResourceStore.forget(key) end)
    topic = ResourceEvents.topic(key)

    # Subscribe directly to the configured bus as well as through the port so a
    # mutation that hard-codes only the subscription or only the broadcast fails.
    assert :ok = ResourceEvents.subscribe(key)
    marker = make_ref()
    assert :ok = Phoenix.PubSub.broadcast(pubsub, topic, {:subscription_probe, marker})
    assert_receive {:subscription_probe, ^marker}, 1_000
    assert :ok = ResourceEvents.unsubscribe(key)
    assert :ok = Phoenix.PubSub.subscribe(pubsub, topic)

    body = %{"id" => 42, "body" => "settings port deposit"}
    assert :ok = ResourceStore.deposit_unless_older(key, body, source: :fetch)
    assert_receive {:github_resource_changed, %{key: ^key, source: :fetch, data?: true}}, 1_000
    assert {:ok, %{data: ^body}} = ResourceStore.fetch(key)
  end

  test "quota emits through the alert sink supplied by static settings", %{root: root} do
    configure(root, alert_sink: alert_sink(self()))
    quota = start_quota(root)
    observe(quota, 500)

    assert {:hold, %{resource: "core"}} = Quota.dispatch_status(quota)
    assert_receive {:configured_alert, "system.github.quota.core.low", opts}, 1_000
    assert opts[:needs_attention]
    assert opts[:reason] =~ "core"
  end

  test "credential disagreements emit through the configured alert sink", %{root: root} do
    configure(root, alert_sink: alert_sink(self()))
    unless Process.whereis(CredentialHeadroom), do: start_supervised!(CredentialHeadroom)
    reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second)
    token_key = "settings-ports-#{System.unique_integer([:positive])}"
    on_exit(fn -> CredentialHeadroom.reconcile_budget_meter(token_key, "core", %{used: 100}, %{limit: 5_000, used: 100, reset_at: reset_at}) end)

    assert :ok = CredentialHeadroom.reconcile_budget_meter(token_key, "core", %{used: 2_000, limit: 5_000}, %{limit: 5_000, used: 100, reset_at: reset_at})

    assert_receive {:configured_alert, "system.github.budget_meter_disagreement", opts}, 1_000
    assert opts[:needs_attention]
    assert opts[:reason] =~ "local billed=2000/5000, GitHub used=100/5000"
  end

  test "the default broker timeout state sends retry alerts through static settings", %{root: root} do
    configure(root, alert_sink: alert_sink(self()))
    now_ms = System.monotonic_time(:millisecond)

    assert {:noreply, state} = BrokerTimeout.handle_cast({:record, now_ms}, %BrokerTimeout{})
    assert state.events == [now_ms]
    assert_receive {:configured_alert, "system.github.budget_broker_retry", opts}, 1_000
    assert opts[:reason] == "Budget broker timeout retry recorded"
    refute opts[:needs_attention]
  end

  test "a budget lease release announces its outcome on the configured PubSub", %{root: root} do
    pubsub = __MODULE__.BudgetPubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    configure(root, pubsub: pubsub, budget_enabled?: false)
    assert :ok = Phoenix.PubSub.subscribe(pubsub, Budget.release_topic())

    # Disabling the broker exercises publication without a host-wide lease or subprocess.
    assert :ok = Budget.release(%{id: "settings-port-lease", token_key: "settings-port-credential"})

    assert_receive {:github_budget_lease_released, %{lease_id: "settings-port-lease", token_key: "settings-port-credential", outcome: :bypass}}, 1_000
  end

  defp configure(root, overrides \\ []) do
    overrides = Keyword.put_new(overrides, :alert_sink, fn _name, _opts -> :ok end)
    Application.put_env(:aiur, :github_access_settings, Settings.new(root, overrides))
  end

  defp start_quota(root) do
    start_supervised!(
      {Quota,
       name: nil, refresh?: false, request_log_path: nil, hold_dir: Path.join(root, "holds"), shell_log_path: Path.join(root, "shell.ndjson"), stale_broker_path: Path.join(root, "stale-broker.json")}
    )
  end

  defp observe(quota, remaining) do
    reset = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_unix() |> Integer.to_string()
    request = %{method: :get, url: "https://api.github.com/repos/settings/ports/issues", token: "test-token", credential_id: "primary"}
    headers = [{"x-ratelimit-resource", "core"}, {"x-ratelimit-limit", "5000"}, {"x-ratelimit-remaining", Integer.to_string(remaining)}, {"x-ratelimit-reset", reset}]
    Quota.observe(quota, request, {:ok, %{status: 200, headers: headers, body: %{}}})
  end

  defp alert_sink(test_pid) do
    fn name, opts ->
      send(test_pid, {:configured_alert, name, opts})
      :ok
    end
  end
end
