defmodule Aiur.BrowserHarness.FixtureAuth do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  @access_modes ~w(read_only writable)

  def authenticate(conn, %{"mode" => mode}) when mode in @access_modes do
    conn
    |> put_req_header("authorization", "Basic " <> Base.encode64("browser_fixture:browser_fixture_password"))
    |> AiurWeb.FinancialDataAccess.call([])
    |> AiurWeb.FinancialDataAccess.call(:persist_session)
    |> put_session("fixture_access", mode)
    |> redirect(to: "/fixture")
  end

  def authenticate(conn, _params), do: send_resp(conn, 404, "unknown synthetic fixture access mode")

  def require_access(conn, _opts) do
    if get_session(conn, "fixture_access") in @access_modes do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "synthetic fixture authentication required")
      |> halt()
    end
  end
end

defmodule Aiur.BrowserHarness.VoiceSTT do
  @moduledoc false

  use GenServer

  def start_link(channel), do: GenServer.start_link(__MODULE__, channel)

  @impl true
  def init(channel), do: {:ok, channel}

  @impl true
  def handle_cast({:push, _pcm}, channel) do
    send(channel, {:elevenlabs_transcript, :partial, "hello"})
    {:noreply, channel}
  end

  def handle_cast(:commit, channel) do
    send(channel, {:elevenlabs_transcript, :final, "hello browser"})
    send(channel, {:elevenlabs_closed})
    {:noreply, channel}
  end

  def handle_cast(:stop, channel), do: {:stop, :normal, channel}
end

defmodule Aiur.BrowserHarness.FixtureAssets do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  @asset_root Path.join(__DIR__, "../assets")

  def health(conn, _params), do: send_resp(conn, 200, "synthetic fixture ready")

  def phoenix_html(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_html/phoenix_html.js")
  def phoenix(conn, _params), do: serve_embedded(conn, "/vendor/phoenix/phoenix.js")
  def phoenix_live_view(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")
  def ticket_context_dialog_hook(conn, _params), do: serve_embedded(conn, "/ticket-context-dialog-hook.js")
  def build_order_grid_hook(conn, _params), do: serve_embedded(conn, "/build-order-grid-hook.js")
  def time_brush_hook(conn, _params), do: serve_embedded(conn, "/time-brush-hook.js")
  def streamdeck_emulator_hook(conn, _params), do: serve_embedded(conn, "/streamdeck-emulator-hook.js")
  def sortable_table_hook(conn, _params), do: serve_embedded(conn, "/sortable-table-hook.js")
  def harness(conn, _params), do: serve_file(conn, "browser_harness.js")
  def worker(conn, _params), do: serve_file(conn, "browser_worker.js")

  defp serve_embedded(conn, asset) do
    case AiurWeb.StaticAssets.fetch(asset) do
      {:ok, content_type, body} -> conn |> put_resp_content_type(content_type) |> send_resp(200, body)
      :error -> send_resp(conn, 404, "asset not found")
    end
  end

  defp serve_file(conn, filename) do
    body = File.read!(Path.join(@asset_root, filename))
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, body)
  end
end
