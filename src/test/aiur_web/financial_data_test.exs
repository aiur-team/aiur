defmodule AiurWeb.FinancialDataTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias AiurWeb.{Endpoint, FinancialData, FinancialDataAccess}

  @session_options Plug.Session.init(
                     store: :cookie,
                     key: "_aiur_key",
                     signing_salt: "aiur-session"
                   )

  setup do
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    configure_endpoint(dashboard_auth_required: true)
    configure_credentials("operator", "secret")
    cache = start_supervised!({FinancialData, name: nil})

    on_exit(fn ->
      restore_application_env(Endpoint, previous_endpoint)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    %{cache: cache}
  end

  test "denied and unsupported queries never invoke or retain the protected provider", %{cache: cache} do
    sentinel = protected_payload()
    test_process = self()

    loader = fn ->
      send(test_process, {:protected_provider_invoked, sentinel})
      sentinel
    end

    log =
      capture_log(fn ->
        assert {:error, :authentication_required} =
                 FinancialData.fetch_provider_meter(cache, nil, :account, 60_000, loader)

        assert {:error, :authentication_required} =
                 FinancialData.fetch(cache, nil, :status_report, :account, 60_000, loader)

        assert {:error, :unsupported_financial_source} =
                 FinancialData.fetch(cache, access_context(), :status_report, :account, 60_000, loader)
      end)

    refute_receive {:protected_provider_invoked, _payload}, 0
    refute inspect(:sys.get_state(cache)) =~ sentinel.account
    refute log =~ sentinel.account
  end

  test "authorized cache entries are isolated by authenticated connection", %{cache: cache} do
    first_context = access_context()
    second_context = access_context()
    counter = :counters.new(1, [])

    loader = fn ->
      :counters.add(counter, 1, 1)
      Map.put(protected_payload(), :load, :counters.get(counter, 1))
    end

    assert {:ok, %{load: 1}} =
             FinancialData.fetch_usage_grouping(cache, first_context, :daily, 60_000, loader)

    assert {:ok, %{load: 1}} =
             FinancialData.fetch_usage_grouping(cache, first_context, :daily, 60_000, loader)

    assert {:ok, %{load: 2}} =
             FinancialData.fetch_usage_grouping(cache, second_context, :daily, 60_000, loader)

    assert :counters.get(counter, 1) == 2
  end

  test "the cache is bounded and an authorized configuration change synchronously evicts stale facts", %{cache: cache} do
    sentinel = protected_payload()

    for index <- 1..12 do
      expected_account = "#{sentinel.account}-#{index}"

      assert {:ok, %{account: ^expected_account}} =
               FinancialData.fetch(
                 cache,
                 access_context(),
                 :provider_meter,
                 {:account, index},
                 60_000,
                 fn -> Map.put(sentinel, :account, expected_account) end
               )
    end

    assert map_size(:sys.get_state(cache).entries) == 8
    assert inspect(:sys.get_state(cache)) =~ sentinel.account
    prior_entries = :sys.get_state(cache).entries

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")

    assert {:error, :authentication_required} =
             FinancialData.fetch(cache, nil, :provider_meter, :account, 60_000, fn -> sentinel end)

    assert :sys.get_state(cache).entries == prior_entries

    assert {:ok, %{account: "CURRENT-GENERATION"}} =
             FinancialData.fetch_provider_meter(
               cache,
               access_context("rotated-secret"),
               :account,
               60_000,
               fn -> %{account: "CURRENT-GENERATION"} end
             )

    refute inspect(:sys.get_state(cache)) =~ sentinel.account
  end

  test "configuration loss while a provider is loading discards the result before cache or reply", %{cache: cache} do
    context = access_context()
    test_process = self()
    sentinel = protected_payload()

    loader = fn ->
      send(test_process, {:protected_loader_started, self()})

      receive do
        :release_protected_loader -> sentinel
      end
    end

    task =
      Task.async(fn ->
        FinancialData.fetch(cache, context, :provider_meter, :account, 60_000, loader)
      end)

    assert_receive {:protected_loader_started, ^cache}, 2_000
    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")
    send(cache, :release_protected_loader)

    assert {:error, :authentication_required} = Task.await(task)
    refute inspect(:sys.get_state(cache)) =~ sentinel.account
  end

  test "provider failures stay structured and never log or cache protected exception text", %{cache: cache} do
    context = access_context()
    sentinel = "acct-provider-exception-financial-sentinel"

    log =
      capture_log(fn ->
        assert {:error, :provider_unavailable} =
                 FinancialData.fetch_provider_meter(cache, context, :account, 0, fn ->
                   raise sentinel
                 end)
      end)

    refute log =~ sentinel
    refute inspect(:sys.get_state(cache)) =~ sentinel
  end

  test "a disconnected caller cannot populate the protected cache", %{cache: cache} do
    context = access_context()
    test_process = self()
    sentinel = protected_payload()

    loader = fn ->
      send(test_process, {:disconnect_loader_started, self()})

      receive do
        :release_disconnect_loader -> sentinel
      end
    end

    caller =
      spawn(fn ->
        FinancialData.fetch(cache, context, :provider_meter, :account, 60_000, loader)
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:disconnect_loader_started, ^cache}, 2_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000
    send(cache, :release_disconnect_loader)
    :sys.get_state(cache)

    refute inspect(:sys.get_state(cache)) =~ sentinel.account
  end

  test "protected PubSub is payload-free and stale queued updates cannot reload", %{cache: cache} do
    context = access_context()
    test_process = self()

    assert :ok = FinancialData.subscribe(context)
    assert :ok = FinancialData.broadcast_update()
    assert_receive {FinancialData, :updated, _opaque_configuration_generation} = message, 2_000
    refute inspect(message) =~ protected_payload().account

    assert {:ok, %{account: "acct-financial-sentinel"}} =
             FinancialData.reload(
               cache,
               context,
               message,
               :provider_meter,
               :account,
               0,
               &protected_payload/0
             )

    cached_entries = :sys.get_state(cache).entries
    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")

    assert {:error, :authentication_required} =
             FinancialData.reload(
               cache,
               context,
               message,
               :provider_meter,
               :account,
               0,
               fn ->
                 send(test_process, :stale_update_invoked_provider)
                 protected_payload()
               end
             )

    refute_receive :stale_update_invoked_provider, 0
    assert :sys.get_state(cache).entries == cached_entries

    assert :ok = FinancialData.broadcast_update()
    refute_receive {FinancialData, :updated, _new_generation}, 0
  end

  test "denied subscriptions and terminated subscribers receive no protected update", %{cache: cache} do
    assert {:error, :authentication_required} = FinancialData.subscribe(nil)

    context = access_context()
    test_process = self()

    subscriber =
      spawn(fn ->
        :ok = FinancialData.subscribe(context)
        send(test_process, {:protected_subscriber_ready, self()})

        receive do
          message -> send(test_process, {:terminated_subscriber_received, message})
        end
      end)

    subscriber_ref = Process.monitor(subscriber)
    assert_receive {:protected_subscriber_ready, ^subscriber}, 2_000
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^subscriber_ref, :process, ^subscriber, :killed}, 2_000

    assert :ok = FinancialData.broadcast_update()
    :sys.get_state(cache)
    refute_receive {:terminated_subscriber_received, _message}, 0
  end

  defp access_context(password \\ "secret") do
    conn =
      :get
      |> conn("/")
      |> Plug.Session.call(@session_options)
      |> fetch_session()
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:#{password}"))
      |> FinancialDataAccess.authenticate_request([])
      |> FinancialDataAccess.persist_session([])

    marker = get_session(conn, FinancialDataAccess.session_key())
    {:ok, context} = FinancialDataAccess.context_from_session(%{FinancialDataAccess.session_key() => marker})
    context
  end

  defp protected_payload do
    %{
      account: "acct-financial-sentinel",
      auth_mode: "oauth-financial-sentinel",
      cost: "usd-financial-sentinel",
      freshness: "fresh-financial-sentinel",
      group: "group-financial-sentinel",
      last_known_good: "lkg-financial-sentinel",
      model: "model-inside-financial-record-sentinel",
      plan: "plan-financial-sentinel",
      quota: "quota-financial-sentinel",
      rate: "rate-financial-sentinel",
      reset_at: "reset-financial-sentinel",
      usage: "usage-financial-sentinel"
    }
  end

  defp configure_credentials(username, password) do
    System.put_env("AIUR_DASHBOARD_USERNAME", username)
    System.put_env("AIUR_DASHBOARD_PASSWORD", password)
  end

  defp configure_endpoint(overrides) do
    config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, Endpoint, config)
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_application_env(key, value), do: Application.put_env(:aiur, key, value)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
