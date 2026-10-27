defmodule AiurWeb.FinancialDataAccess do
  @moduledoc """
  Establishes and verifies the server-side authorization boundary for financial
  dashboard data.

  A successful HTTP Basic-Auth request receives an opaque proof in the signed
  dashboard session. LiveView verifies that proof against the current endpoint
  authentication generation before retaining an access context in socket
  private state. The only public assign is a versioned, value-free capability.
  """

  import Plug.Conn

  alias AiurWeb.FinancialDataAccess.{Generation, Proof}

  @behaviour Plug

  @version 1
  @session_key "financial_data_access"
  @conn_private_key :aiur_financial_data_session_marker
  @socket_private_key :aiur_financial_data_access
  @missing_credentials_message "Dashboard authentication is not configured. Set AIUR_DASHBOARD_USERNAME and AIUR_DASHBOARD_PASSWORD."

  defmodule Context do
    @moduledoc false

    @enforce_keys [:configuration_generation, :connection_generation, :issued_at, :proof]
    defstruct [:configuration_generation, :connection_generation, :issued_at, :proof]

    @type t :: %__MODULE__{
            configuration_generation: String.t(),
            connection_generation: String.t(),
            issued_at: integer(),
            proof: String.t()
          }
  end

  @type identity :: {String.t(), String.t()}

  @doc false
  @impl Plug
  def init(opts), do: opts

  @doc false
  @impl Plug
  def call(conn, :persist_session), do: persist_session(conn, [])
  def call(conn, opts) when is_list(opts), do: authenticate_request(conn, opts)

  @doc "Authenticates a dashboard request and stages opaque session evidence."
  @spec authenticate_request(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def authenticate_request(conn, opts) do
    browser? = Keyword.get(opts, :browser?, false)

    case context_from_session(get_session(conn)) do
      {:ok, _context} ->
        put_private(conn, @conn_private_key, get_session(conn, @session_key))

      :error ->
        if browser? and not browser_basic_auth?() do
          conn
          |> Phoenix.Controller.redirect(to: "/auth/login")
          |> halt()
        else
          authenticate_without_session(conn, opts)
        end
    end
  end

  defp authenticate_without_session(conn, opts) do
    case Proof.configuration(opts, @version) do
      {:ok, config} ->
        authenticate_configured_request(conn, config)

      {:error, :authentication_required} ->
        conn
        |> Plug.BasicAuth.request_basic_auth(realm: "Aiur")
        |> halt()

      {:error, :authentication_not_configured} ->
        conn
        |> send_resp(503, @missing_credentials_message)
        |> halt()
    end
  end

  defp browser_basic_auth? do
    AiurWeb.EndpointConfig.get(:browser_basic_auth) != false
  rescue
    _ -> true
  end

  defp authenticate_configured_request(conn, config) do
    # Credentials present means the request must prove them, regardless of the
    # `required?` setting. `required?` only distinguishes how an *unconfigured*
    # request fails (401 challenge vs 503 refusal); it must never turn a
    # configured endpoint into an open pass-through.
    authenticated =
      Plug.BasicAuth.basic_auth(conn,
        username: config.username,
        password: config.password,
        realm: "Aiur"
      )

    if authenticated.halted do
      authenticated
    else
      put_private(authenticated, @conn_private_key, Proof.new_session_marker(config, @version))
    end
  end

  @doc "Persists staged auth evidence only after the browser session is fetched."
  @spec persist_session(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def persist_session(conn, _opts) do
    case conn.private[@conn_private_key] do
      %{} = marker -> put_session(conn, @session_key, marker)
      _other -> delete_session(conn, @session_key)
    end
  end

  @doc "Verifies the session proof before any LiveView mount receives authority."
  @spec on_mount(term(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(_hook, _params, session, socket) do
    {context, capability} =
      case context_from_session(session) do
        {:ok, context} -> {context, %{state: :authorized, version: @version}}
        :error -> {nil, locked_capability()}
      end

    socket =
      socket
      |> Phoenix.Component.assign(:financial_data_capability, capability)
      |> Phoenix.LiveView.put_private(@socket_private_key, context)

    {:cont, socket}
  end

  @doc "Returns the verified context retained outside LiveView assigns."
  @spec context(Phoenix.LiveView.Socket.t()) :: Context.t() | nil
  def context(%Phoenix.LiveView.Socket{} = socket), do: socket.private[@socket_private_key]

  @doc "Builds an access context only from a valid marker for the current config."
  @spec context_from_session(map()) :: {:ok, Context.t()} | :error
  def context_from_session(session), do: Proof.context_from_session(session, @session_key, @version)

  @doc "Revalidates a context against the live authentication configuration."
  @spec authorize(Context.t() | nil) :: :ok | {:error, :authentication_required}
  def authorize(context) do
    case identity(context) do
      {:ok, _identity} -> :ok
      {:error, :authentication_required} = error -> error
    end
  end

  @doc false
  @spec identity(Context.t() | nil) :: {:ok, identity()} | {:error, :authentication_required}
  def identity(context), do: Proof.identity(context, @version)

  @doc false
  @spec current_configuration_generation() :: {:ok, String.t()} | {:error, :authentication_required}
  def current_configuration_generation, do: Proof.current_configuration_generation(@version)

  @doc false
  @spec subscribe_to_configuration_changes(pid()) :: :ok
  def subscribe_to_configuration_changes(listener \\ self()), do: Generation.subscribe(listener)

  @doc "Stable, accessible, and value-free contract for locked consumers."
  @spec locked_capability() :: map()
  def locked_capability do
    %{
      accessible_name: "Financial data locked",
      authentication_path: "Sign in with the configured dashboard credentials.",
      reason: "Authentication is required to access financial data.",
      state: :locked,
      version: @version
    }
  end

  @doc false
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc false
  @spec new_browser_session_marker() :: {:ok, map()} | {:error, term()}
  def new_browser_session_marker do
    case Proof.configuration([], @version) do
      {:ok, config} -> {:ok, Proof.new_session_marker(config, @version)}
      error -> error
    end
  end
end
