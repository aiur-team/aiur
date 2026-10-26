defmodule Aiur.Instance.LeaseStoreTest do
  use ExUnit.Case, async: false

  alias Aiur.Instance.DispatchClaim
  alias Aiur.Instance.LeaseStore
  alias Aiur.TrackerIdentity

  test "ticket keys normalize issue and provider shapes to one repository-qualified key" do
    assert {:ok, "acme/widgets"} = LeaseStore.repository_key("Acme/Widgets")
    assert {:error, :invalid_repository} = LeaseStore.repository_key("not-a-repo")

    identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "Acme",
      repository: "Widgets",
      provider_id: "node-42",
      identifier: "42",
      reason: nil
    }

    issue = %Aiur.Issue{id: "42", identifier: "42", tracker_identity: identity}

    assert {:ok, "acme/widgets#42"} = LeaseStore.ticket_key(issue)
    assert {:error, :invalid_ticket_key} = LeaseStore.ticket_key(%{issue | identifier: "43"})
    assert {:ok, "acme/widgets#42"} = LeaseStore.ticket_key(identity)
    assert {:ok, "acme/widgets#42"} = LeaseStore.ticket_key("Acme/Widgets#42")
    assert {:ok, "acme/widgets#42"} = LeaseStore.ticket_key(%{"number" => 42, "repository" => %{"full_name" => "Acme/Widgets"}})
    assert {:ok, configured_key} = LeaseStore.ticket_key(42)
    assert {:ok, ^configured_key} = LeaseStore.ticket_key("42")
    assert {:ok, ^configured_key} = LeaseStore.ticket_key("#42")
    assert {:error, :invalid_ticket_key} = LeaseStore.ticket_key(%{number: "unknown"})
    assert {:error, :invalid_ticket_key} = LeaseStore.ticket_key(%{"number" => 42, "repository" => "acme/widgets/extra"})
  end

  test "leader claim and renew return store_unavailable when the store server is down" do
    dead_server =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :stop -> :ok
           end
         end}
      )

    ref = Process.monitor(dead_server)
    send(dead_server, :stop)
    assert_receive {:DOWN, ^ref, :process, ^dead_server, :normal}, 1_000

    for result <- [LeaseStore.claim_leader("owner/repo", server: dead_server), LeaseStore.renew_leader("owner/repo", server: dead_server)] do
      assert {:error, {:store_unavailable, _reason}} = result
    end
  end

  test "an unavailable PostgreSQL store leaves its supervisor and sibling services alive" do
    parent = self()
    previous = Application.get_env(:aiur, :lease_database_url)
    Application.put_env(:aiur, :lease_database_url, "postgres://unused:unused@127.0.0.1:1/aiur")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aiur, :lease_database_url, previous),
        else: Application.delete_env(:aiur, :lease_database_url)
    end)

    server = Module.concat(__MODULE__, "Unavailable#{System.unique_integer([:positive])}")
    observer = Module.concat(__MODULE__, "Observer#{System.unique_integer([:positive])}")

    children = [
      LeaseStore.child_spec(
        name: server,
        url: "postgres://unused:unused@127.0.0.1:1/aiur",
        reconnect_initial_ms: 20,
        reconnect_max_ms: 40,
        connect_fun: fn _state -> {:error, :offline} end,
        alert_fun: fn topic, _opts ->
          send(parent, {:store_alert, topic})
          :ok
        end
      ),
      {Task.Supervisor, name: observer}
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(supervisor), do: safe_stop_supervisor(supervisor) end)

    assert_receive {:store_alert, "system.instance.ownership_unknown"}, 5_000

    result =
      DispatchClaim.call("owner/repo#42", fn -> send(parent, :workspace_started) end, claim_fun: fn key -> LeaseStore.claim(key, server: server) end)

    assert match?({:error, {:shared_lease_unavailable, _}}, result)
    refute_receive :workspace_started, 0
    assert Process.alive?(supervisor)
    assert Process.alive?(Process.whereis(server))
    assert Process.alive?(Process.whereis(observer))
    refute_receive {:store_alert, "system.instance.ownership_unknown"}, 100
  end

  test "a worker stops after failed renewals pass the safe lease deadline" do
    previous = Application.get_env(:aiur, :lease_database_url)
    Application.put_env(:aiur, :lease_database_url, "postgres://test.invalid/aiur")

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :lease_database_url, previous), else: Application.delete_env(:aiur, :lease_database_url)
    end)

    server = Module.concat(__MODULE__, "Renewal#{System.unique_integer([:positive])}")
    {:ok, store} = LeaseStore.start_link(name: server, url: nil, instance_id: "self", leases: MapSet.new(["owner/repo#42"]))
    Process.unlink(store)
    on_exit(fn -> if Process.alive?(store), do: safe_stop_genserver(store) end)

    {:ok, clock} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        :ok =
          LeaseStore.watch("owner/repo#42",
            server: server,
            renew_interval_ms: 1,
            ttl_ms: 10,
            renew_margin_ms: 3,
            monotonic_now: fn -> Agent.get(clock, & &1) end,
            renew_fun: fn _key, _server, _ttl ->
              Agent.update(clock, fn _ -> 7 end)
              {:error, :offline}
            end
          )

        send(parent, :watch_started)

        receive do
        after
          :infinity -> :ok
        end
      end)

    assert_receive :watch_started, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, {:shared_ticket_lease_lost, "owner/repo#42"}}, 1_000
  end

  test "a blocked renewal cannot keep a worker alive past its lease deadline" do
    previous = Application.get_env(:aiur, :lease_database_url)
    Application.put_env(:aiur, :lease_database_url, "postgres://test.invalid/aiur")

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :lease_database_url, previous), else: Application.delete_env(:aiur, :lease_database_url)
    end)

    server = Module.concat(__MODULE__, "BlockedRenewal#{System.unique_integer([:positive])}")
    {:ok, store} = LeaseStore.start_link(name: server, url: nil, instance_id: "self", leases: MapSet.new(["owner/repo#42"]))
    Process.unlink(store)
    on_exit(fn -> if Process.alive?(store), do: safe_stop_genserver(store) end)
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        :ok =
          LeaseStore.watch("owner/repo#42",
            server: server,
            renew_interval_ms: 1,
            ttl_ms: 200,
            renew_margin_ms: 50,
            renew_fun: fn _key, _server, _ttl ->
              send(parent, :blocked_renewal_started)
              receive do: (:never -> :ok)
            end
          )

        receive do: (:never -> :ok)
      end)

    assert_receive :blocked_renewal_started, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, {:shared_ticket_lease_lost, "owner/repo#42"}}, 500
  end

  @tag skip: is_nil(System.get_env("AIUR_LEASE_DATABASE_URL"))
  test "PostgreSQL atomically admits one claimant across independent store processes" do
    case System.get_env("AIUR_LEASE_DATABASE_URL") do
      nil ->
        flunk("CI must configure AIUR_LEASE_DATABASE_URL for this integration test")

      url ->
        previous = Application.get_env(:aiur, :lease_database_url)
        Application.put_env(:aiur, :lease_database_url, url)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:aiur, :lease_database_url, previous),
            else: Application.delete_env(:aiur, :lease_database_url)
        end)

        suffix = System.unique_integer([:positive])
        left = Module.concat(__MODULE__, "Left#{suffix}")
        right = Module.concat(__MODULE__, "Right#{suffix}")
        left_id = "lease-left-#{suffix}"
        right_id = "lease-right-#{suffix}"
        key = "lease-test/repo##{suffix}"

        {:ok, left_pid} = LeaseStore.start_link(name: left, url: url, instance_id: left_id)
        {:ok, right_pid} = LeaseStore.start_link(name: right, url: url, instance_id: right_id)

        on_exit(fn ->
          if Process.alive?(left_pid), do: safe_stop_genserver(left_pid)
          if Process.alive?(right_pid), do: safe_stop_genserver(right_pid)
        end)

        assert LeaseStore.claim(key, server: left) == :acquired
        assert LeaseStore.claim(key, server: right) == :held
        assert LeaseStore.holder(key, server: right) == {:held, left_id}
        assert LeaseStore.owned?(key, server: left, instance_id: left_id)
        refute LeaseStore.owned?(key, server: right, instance_id: right_id)
        assert :ok = LeaseStore.release(key, server: left)

        results =
          [
            Task.async(fn -> LeaseStore.claim(key, server: left) end),
            Task.async(fn -> LeaseStore.claim(key, server: right) end)
          ]
          |> Enum.map(&Task.await(&1, 5_000))

        assert Enum.count(results, &(&1 == :acquired)) == 1
        assert Enum.count(results, &(&1 == :held)) == 1

        budget_key = "github-budget-test-#{suffix}"
        assert {:ok, :admitted} = LeaseStore.admit_github_budget("budget-left-#{suffix}", budget_key, "graphql", "left", 100, 60, server: left)
        assert {:ok, {:held, %DateTime{}}} = LeaseStore.admit_github_budget("budget-right-#{suffix}", budget_key, "graphql", "right", 100, 60, server: right)
        observed_at = DateTime.utc_now()

        provider_snapshot = %Aiur.ProviderMeterSnapshot{
          provider: :codex,
          backend: :app_server,
          identity_scope: :account,
          provider_account_generation: "generation-#{suffix}",
          observed_at: observed_at,
          auth_mode: :subscription,
          freshness: :fresh,
          health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
          windows: %{"weekly" => %{used: 7}}
        }

        assert :ok = LeaseStore.publish_provider_meter(provider_snapshot, server: left)
        assert {:ok, ^provider_snapshot} = LeaseStore.shared_provider_meter(:codex, server: right)

        expiry_key = "lease-test/expiry##{suffix}"
        assert LeaseStore.claim(expiry_key, server: left, ttl_ms: 1_000, grace_ms: 10_000) == :acquired
        assert LeaseStore.claim(expiry_key, server: right, ttl_ms: 1_000, grace_ms: 10_000) == :held

        connection = :sys.get_state(left).conn

        assert {:ok, %{num_rows: 1}} =
                 Postgrex.query(
                   connection,
                   "UPDATE aiur_ticket_leases SET expires_at = clock_timestamp() - interval '1 second' WHERE ticket_key = $1",
                   [expiry_key]
                 )

        assert LeaseStore.claim(expiry_key, server: right, ttl_ms: 1_000, grace_ms: 10_000) == :held

        assert {:ok, %{num_rows: 1}} =
                 Postgrex.query(
                   connection,
                   "UPDATE aiur_ticket_leases SET expires_at = clock_timestamp() - interval '11 seconds' WHERE ticket_key = $1",
                   [expiry_key]
                 )

        assert LeaseStore.claim(expiry_key, server: right, ttl_ms: 1_000, grace_ms: 10_000) == :acquired
        assert LeaseStore.renew(expiry_key, server: left, ttl_ms: 100) == {:error, :lease_lost}
        assert :ok = LeaseStore.release(expiry_key, server: left)
        assert LeaseStore.holder(expiry_key, server: right) == {:held, right_id}

        repository = "lease-test/leader-#{suffix}"
        assert LeaseStore.claim_leader(repository, server: left, ttl_ms: 5_000) == :acquired
        assert LeaseStore.claim_leader(repository, server: right, ttl_ms: 5_000) == :held
        assert %{instance_id: ^left_id, heartbeat_at: %DateTime{}, expires_at: %DateTime{}} = LeaseStore.leader(repository, server: right)
        assert LeaseStore.leader_owned?(repository, server: left, instance_id: left_id)
        refute LeaseStore.leader_owned?(repository, server: right, instance_id: right_id)

        assert {:ok, %{num_rows: 1}} =
                 Postgrex.query(
                   connection,
                   "UPDATE aiur_repository_leases SET expires_at = clock_timestamp() - interval '1 second' WHERE repository = $1",
                   [repository]
                 )

        assert LeaseStore.claim_leader(repository, server: right, ttl_ms: 5_000) == :acquired
        assert LeaseStore.renew_leader(repository, server: left, ttl_ms: 5_000) == {:error, :lease_lost}
        assert %{instance_id: ^right_id} = LeaseStore.leader(repository, server: left)
    end
  end

  defp safe_stop_genserver(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp safe_stop_supervisor(pid) do
    Supervisor.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
