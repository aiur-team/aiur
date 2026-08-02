defmodule AiurWeb.OperatorControlCenter.ProviderMeterSourceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.{Endpoint, FinancialData, FinancialDataAccess}
  alias AiurWeb.OperatorControlCenter.ProviderMeterSource

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_key", signing_salt: "aiur-session")

  setup do
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    configure_endpoint(dashboard_auth_required: true)
    configure_credentials("operator", "secret")
    # ProviderMeterSource reads through the facade already running under its
    # module name in the application supervision tree.

    on_exit(fn ->
      restore(Endpoint, previous_endpoint)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    :ok
  end

  test "a denied context yields no snapshot and never invokes the protected provider" do
    test_process = self()

    sentinel = fn provider, _binding ->
      send(test_process, {:protected_provider_invoked, provider})
      ProviderMeterSnapshot.unknown(provider, :app_server)
    end

    snapshots = ProviderMeterSource.load(nil, snapshot_fun: sentinel)

    assert snapshots == %{codex: nil, claude: nil, fake: nil}
    refute_receive {:protected_provider_invoked, _provider}, 0
  end

  test "an authorized context returns each provider's snapshot through the facade" do
    context = access_context()

    snapshots =
      ProviderMeterSource.load(context, snapshot_fun: fn provider, _binding -> snapshot(provider) end)

    assert %ProviderMeterSnapshot{provider: :codex} = snapshots.codex
    assert %ProviderMeterSnapshot{provider: :claude} = snapshots.claude
    assert %ProviderMeterSnapshot{provider: :fake} = snapshots.fake
  end

  test "one provider's read failure is isolated from the healthy provider" do
    context = access_context()

    fun = fn
      :codex, _binding -> raise "codex boom"
      :claude, _binding -> snapshot(:claude)
      :fake, _binding -> snapshot(:fake)
    end

    snapshots = ProviderMeterSource.load(context, snapshot_fun: fun)

    assert snapshots.codex == nil
    assert %ProviderMeterSnapshot{provider: :claude} = snapshots.claude
    assert %ProviderMeterSnapshot{provider: :fake} = snapshots.fake
  end

  test "reload against a mismatched identity message reads nothing" do
    context = access_context()
    test_process = self()

    sentinel = fn provider, _binding ->
      send(test_process, {:protected_provider_invoked, provider})
      snapshot(provider)
    end

    snapshots = ProviderMeterSource.reload(context, {FinancialData, :updated, {"bogus", "identity"}}, snapshot_fun: sentinel)

    assert snapshots == %{codex: nil, claude: nil, fake: nil}
    refute_receive {:protected_provider_invoked, _provider}, 0
  end

  test "reload against the connection identity re-reads each provider" do
    context = access_context()
    {:ok, identity} = FinancialDataAccess.identity(context)

    snapshots =
      ProviderMeterSource.reload(context, {FinancialData, :updated, identity}, snapshot_fun: fn provider, _binding -> snapshot(provider) end)

    assert %ProviderMeterSnapshot{provider: :codex} = snapshots.codex
    assert %ProviderMeterSnapshot{provider: :claude} = snapshots.claude
    assert %ProviderMeterSnapshot{provider: :fake} = snapshots.fake
  end

  defp snapshot(provider) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-#{provider}",
      health: %{state: :healthy, failure: nil, last_observed_at: nil, last_source_version: 1}
    }
  end

  defp access_context do
    conn =
      :get
      |> conn("/")
      |> Plug.Session.call(@session_options)
      |> fetch_session()
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> FinancialDataAccess.authenticate_request([])
      |> FinancialDataAccess.persist_session([])

    marker = get_session(conn, FinancialDataAccess.session_key())
    {:ok, context} = FinancialDataAccess.context_from_session(%{FinancialDataAccess.session_key() => marker})
    context
  end

  defp configure_endpoint(overrides) do
    config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, Endpoint, config)
  end

  defp configure_credentials(username, password) do
    System.put_env("AIUR_DASHBOARD_USERNAME", username)
    System.put_env("AIUR_DASHBOARD_PASSWORD", password)
  end

  defp restore(key, nil), do: Application.delete_env(:aiur, key)
  defp restore(key, value), do: Application.put_env(:aiur, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
