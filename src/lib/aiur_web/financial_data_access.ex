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

  defmodule Context do
    @moduledoc false

    @enforce_keys [:configuration_generation, :connection_generation, :proof]
    defstruct [:configuration_generation, :connection_generation, :proof]

    @type t :: %__MODULE__{
            configuration_generation: String.t(),
            connection_generation: String.t(),
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
    case Proof.configuration(opts, @version) do
      {:ok, config} ->
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

      {:error, :authentication_required} ->
        conn
        |> Plug.BasicAuth.request_basic_auth(realm: "Aiur")
        |> halt()

      {:error, :authentication_not_configured} ->
        conn
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
end
