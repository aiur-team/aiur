defmodule AiurWeb.FinancialDataAccessTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.{Endpoint, FinancialDataAccess}

  @session_options Plug.Session.init(
                     store: :cookie,
                     key: "_aiur_key",
                     signing_salt: "aiur-session"
                   )

  setup do
    previous_endpoint = Application.get_env(:aiur, Endpoint)
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    configure_endpoint(dashboard_auth_required: false, dashboard_writable: false)
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_application_env(Endpoint, previous_endpoint)
      restore_env("AIUR_DASHBOARD_USERNAME", previous_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", previous_password)
    end)

    :ok
  end

  test "configured Basic Auth creates an opaque session-bound access context" do
    configure_credentials("operator", "financial-auth-secret")
    configure_endpoint(dashboard_auth_required: true, dashboard_writable: false)

    conn = authenticated_conn("operator", "financial-auth-secret")
    marker = get_session(conn, FinancialDataAccess.session_key())

    assert is_map(marker)
    assert marker["version"] == 1
    refute inspect(marker) =~ "operator"
    refute inspect(marker) =~ "financial-auth-secret"

    assert {:ok, context} = FinancialDataAccess.context_from_session(%{FinancialDataAccess.session_key() => marker})
    assert :ok = FinancialDataAccess.authorize(context)

    socket = live_socket()

    assert {:cont, mounted} =
             FinancialDataAccess.on_mount(
               :default,
               %{},
               %{FinancialDataAccess.session_key() => marker},
               socket
             )

    assert mounted.assigns.financial_data_capability == %{state: :authorized, version: 1}
    assert mounted.private.aiur_financial_data_access == context
  end

  test "Plug callbacks fail closed and expose only verified socket-private context" do
    assert FinancialDataAccess.init(required?: true) == [required?: true]

    required = FinancialDataAccess.call(session_conn(), required?: true)
    assert required.status == 401
    assert required.halted

    configure_credentials("operator", "secret")
    configure_endpoint(dashboard_auth_required: true)

    conn =
      session_conn()
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> FinancialDataAccess.call([])
      |> FinancialDataAccess.call(:persist_session)

    session = %{FinancialDataAccess.session_key() => get_session(conn, FinancialDataAccess.session_key())}
    assert {:cont, mounted} = FinancialDataAccess.on_mount(:default, %{}, session, live_socket())
    assert %FinancialDataAccess.Context{} = FinancialDataAccess.context(mounted)
  end

  test "dashboard LiveView routes install the financial on-mount contract" do
    live_routes = Enum.filter(AiurWeb.Router.__routes__(), &(&1.plug == Phoenix.LiveView.Plug))

    assert Enum.map(live_routes, & &1.path) == [
             "/",
             "/decisions",
             "/decisions/:decision_id",
             "/build-orders",
             "/build-orders/:root_number"
           ]

    for route <- live_routes do
      {_view, _action, _route_opts, %{name: :dashboard, extra: %{on_mount: [%{id: {FinancialDataAccess, :default}}]}}} =
        route.metadata.phoenix_live_view
    end
  end

  test "absent, partial, invalid, and stale authentication evidence stays content-free and locked" do
    sentinel = "acct-financial-sentinel-plan-quota-reset-lkg"

    assert {:cont, absent} = FinancialDataAccess.on_mount(:default, %{}, %{}, live_socket())
    assert absent.assigns.financial_data_capability == FinancialDataAccess.locked_capability()
    assert absent.private.aiur_financial_data_access == nil
    refute inspect(absent) =~ sentinel

    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    partial =
      session_conn()
      |> FinancialDataAccess.authenticate_request([])
      |> FinancialDataAccess.persist_session([])

    assert get_session(partial, FinancialDataAccess.session_key()) == nil

    configure_credentials("operator", "secret")
    configure_endpoint(dashboard_auth_required: true)

    invalid = authenticated_conn("operator", "wrong-secret")
    assert invalid.status == 401
    assert invalid.halted

    valid = authenticated_conn("operator", "secret")
    marker = get_session(valid, FinancialDataAccess.session_key())
    stale_marker = Map.put(marker, "proof", sentinel)

    assert :error = FinancialDataAccess.context_from_session(%{FinancialDataAccess.session_key() => stale_marker})

    assert {:cont, stale} =
             FinancialDataAccess.on_mount(
               :default,
               %{},
               %{FinancialDataAccess.session_key() => stale_marker},
               live_socket()
             )

    assert stale.assigns.financial_data_capability == FinancialDataAccess.locked_capability()
    assert stale.private.aiur_financial_data_access == nil
    refute inspect(stale) =~ sentinel
  end

  test "an optional unauthenticated request clears prior session authority" do
    configure_credentials("operator", "secret")
    configure_endpoint(dashboard_auth_required: false)
    valid = authenticated_conn("operator", "secret")
    marker = get_session(valid, FinancialDataAccess.session_key())
    assert is_map(marker)

    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    cleared =
      session_conn()
      |> put_session(FinancialDataAccess.session_key(), marker)
      |> FinancialDataAccess.authenticate_request([])
      |> FinancialDataAccess.persist_session([])

    assert get_session(cleared, FinancialDataAccess.session_key()) == nil
  end

  test "credential or enforcement-generation changes revoke an existing context" do
    configure_credentials("operator", "first-secret")
    configure_endpoint(dashboard_auth_required: true)

    context = access_context("operator", "first-secret")
    assert :ok = FinancialDataAccess.authorize(context)

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")
    assert {:error, :authentication_required} = FinancialDataAccess.authorize(context)

    rotated = access_context("operator", "rotated-secret")
    assert :ok = FinancialDataAccess.authorize(rotated)

    configure_endpoint(dashboard_auth_required: false)
    assert {:error, :authentication_required} = FinancialDataAccess.authorize(rotated)
  end

  test "an authentication configuration generation never becomes valid again after an A to B to A replay" do
    configure_credentials("operator", "first-secret")
    configure_endpoint(dashboard_auth_required: true)

    original = access_context("operator", "first-secret")
    assert :ok = FinancialDataAccess.authorize(original)

    System.put_env("AIUR_DASHBOARD_PASSWORD", "rotated-secret")
    assert {:error, :authentication_required} = FinancialDataAccess.authorize(original)

    System.put_env("AIUR_DASHBOARD_PASSWORD", "first-secret")
    assert {:error, :authentication_required} = FinancialDataAccess.authorize(original)

    replacement = access_context("operator", "first-secret")
    assert :ok = FinancialDataAccess.authorize(replacement)
    refute replacement.configuration_generation == original.configuration_generation
  end

  test "username and endpoint signing-key changes revoke existing proof material" do
    configure_credentials("operator", "secret")
    configure_endpoint(dashboard_auth_required: true)
    context = access_context("operator", "secret")

    System.put_env("AIUR_DASHBOARD_USERNAME", "replacement-operator")
    assert {:error, :authentication_required} = FinancialDataAccess.authorize(context)

    replacement = access_context("replacement-operator", "secret")
    configure_endpoint(secret_key_base: String.duplicate("r", 64), dashboard_auth_required: true)
    assert {:error, :authentication_required} = FinancialDataAccess.authorize(replacement)
  end

  test "financial reads remain independent from writable and supervisor authority" do
    configure_credentials("operator", "secret")
    configure_endpoint(dashboard_auth_required: true, dashboard_writable: false)
    context = access_context("operator", "secret")

    assert :ok = FinancialDataAccess.authorize(context)

    configure_endpoint(dashboard_auth_required: true, dashboard_writable: true)
    assert :ok = FinancialDataAccess.authorize(context)

    System.put_env("AIUR_SUPERVISOR_TOKEN", String.duplicate("s", 32))
    assert :ok = FinancialDataAccess.authorize(context)
  after
    System.delete_env("AIUR_SUPERVISOR_TOKEN")
  end

  test "locked capability is stable, accessible, and contains no financial fact fields" do
    capability = FinancialDataAccess.locked_capability()

    assert capability == %{
             accessible_name: "Financial data locked",
             authentication_path: "Sign in with the configured dashboard credentials.",
             reason: "Authentication is required to access financial data.",
             state: :locked,
             version: 1
           }

    for forbidden <- ~w(provider account usage cost auth_mode plan tier quota rate credit percentage limit reset freshness lkg) do
      refute Map.has_key?(capability, String.to_atom(forbidden))
    end
  end

  test "client-controlled mount parameters cannot grant or enrich financial capability" do
    sentinel = "provider-account-plan-quota-financial-sentinel"

    assert {:cont, socket} =
             FinancialDataAccess.on_mount(
               :default,
               %{"financial_data_access" => %{"state" => "authorized", "payload" => sentinel}},
               %{},
               live_socket()
             )

    assert socket.assigns.financial_data_capability == FinancialDataAccess.locked_capability()
    assert socket.private.aiur_financial_data_access == nil
    refute inspect(socket) =~ sentinel
  end

  defp access_context(username, password) do
    conn = authenticated_conn(username, password)
    marker = get_session(conn, FinancialDataAccess.session_key())
    {:ok, context} = FinancialDataAccess.context_from_session(%{FinancialDataAccess.session_key() => marker})
    context
  end

  defp authenticated_conn(username, password) do
    session_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("#{username}:#{password}"))
    |> FinancialDataAccess.authenticate_request([])
    |> FinancialDataAccess.persist_session([])
  end

  defp session_conn do
    :get
    |> conn("/")
    |> Plug.Session.call(@session_options)
    |> fetch_session()
  end

  defp live_socket do
    %Phoenix.LiveView.Socket{
      endpoint: Endpoint,
      assigns: %{__changed__: %{}},
      private: %{}
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
