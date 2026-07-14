Code.require_file("../support/browser_harness/fixtures.ex", __DIR__)

defmodule Aiur.BrowserHarness.FixtureLayout do
  use Phoenix.Component

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Aiur browser harness fixture</title>
        <style>
          :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
          body { margin: 0; }
          main { display: grid; gap: 1rem; padding: 1rem; }
          nav, .controls { display: flex; flex-wrap: wrap; gap: .5rem; }
          button:focus-visible, [tabindex="0"]:focus-visible { outline: 3px solid currentColor; outline-offset: 3px; }
          #graph-viewport { border: 1px solid currentColor; min-height: 8rem; overflow: auto; padding: 1rem; }
          #graph-content { min-width: 36rem; }
          @media (prefers-reduced-motion: no-preference) { #graph-content { transition: transform 120ms ease; } }
        </style>
        <script defer src="/assets/phoenix_html.js"></script>
        <script defer src="/assets/phoenix.js"></script>
        <script defer src="/assets/phoenix_live_view.js"></script>
        <script defer src="/assets/browser_harness.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            window.liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: window.BrowserHarnessHooks,
              params: {_csrf_token: csrfToken}
            });
            window.liveSocket.connect();
          });
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule Aiur.BrowserHarness.FixtureLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.BrowserHarness.Fixtures

  @impl true
  def mount(_params, _session, socket) do
    fixture = Fixtures.graph(20)

    {:ok,
     socket
     |> assign(:fixture, fixture)
     |> assign(:mode, :read_only)
     |> assign(:theme, :light)
     |> assign(:interaction, "Awaiting input")
     |> assign(:view, :overview)
     |> assign(:reduced_motion, false)
     |> assign(:worker_ready, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "details", do: :details, else: :overview
    {:noreply, assign(socket, :view, view)}
  end

  @impl true
  def handle_event("navigate", %{"view" => view}, socket) when view in ["overview", "details"] do
    {:noreply, push_patch(socket, to: "/?view=#{view}")}
  end

  def handle_event("set-mode", %{"mode" => "writable"}, socket), do: {:noreply, assign(socket, :mode, :writable)}
  def handle_event("set-mode", _params, socket), do: {:noreply, assign(socket, :mode, :read_only)}

  def handle_event("set-theme", %{"theme" => "dark"}, socket), do: {:noreply, assign(socket, :theme, :dark)}
  def handle_event("set-theme", _params, socket), do: {:noreply, assign(socket, :theme, :light)}

  def handle_event("input", %{"kind" => kind}, socket) when kind in ["pointer", "keyboard", "touch"] do
    {:noreply, assign(socket, :interaction, "#{kind} input received")}
  end

  def handle_event("worker-ready", _params, socket), do: {:noreply, assign(socket, :worker_ready, true)}

  def handle_event("reduced-motion", %{"reduced" => reduced_motion}, socket) when is_boolean(reduced_motion) do
    {:noreply, assign(socket, :reduced_motion, reduced_motion)}
  end

  def handle_event("live-update", _params, socket) do
    {:noreply, assign(socket, :fixture, Fixtures.live_updates().next)}
  end

  @impl true
  def render(assigns) do
    counts = Fixtures.counts(assigns.fixture)
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <main id="fixture-root" data-fixture-ready="true" data-mode={@mode} data-theme={@theme} aria-labelledby="fixture-title">
      <header>
        <h1 id="fixture-title">Synthetic LiveView browser fixture</h1>
        <p id="fixture-status" role="status">{@interaction}</p>
      </header>

      <nav aria-label="Fixture navigation">
        <button id="navigate-overview" type="button" phx-click="navigate" phx-value-view="overview" aria-current={if @view == :overview, do: "page"}>Overview</button>
        <button id="navigate-details" type="button" phx-click="navigate" phx-value-view="details" aria-current={if @view == :details, do: "page"}>Details</button>
      </nav>

      <section aria-labelledby="mode-title">
        <h2 id="mode-title">Synthetic mode</h2>
        <div class="controls">
          <button id="read-only-mode" type="button" phx-click="set-mode" phx-value-mode="read_only">Read only</button>
          <button id="writable-mode" type="button" phx-click="set-mode" phx-value-mode="writable">Writable</button>
          <span id="mode-status">{@mode}</span>
        </div>
      </section>

      <section aria-labelledby="input-title">
        <h2 id="input-title">Input paths</h2>
        <div class="controls">
          <button id="pointer-input" type="button" phx-click="input" phx-value-kind="pointer">Pointer input</button>
          <button id="keyboard-input" type="button" phx-click="input" phx-value-kind="keyboard">Keyboard input</button>
          <button id="touch-input" type="button" phx-click="input" phx-value-kind="touch">Touch input</button>
          <button id="theme-light" type="button" phx-click="set-theme" phx-value-theme="light">Light theme</button>
          <button id="theme-dark" type="button" phx-click="set-theme" phx-value-theme="dark">Dark theme</button>
        </div>
      </section>

      <section aria-labelledby="worker-title">
        <h2 id="worker-title">Worker and LiveView state</h2>
        <p id="worker-status" phx-hook="BrowserHarness" data-worker-ready={to_string(@worker_ready)} data-live-status="connected">Worker pending</p>
        <button id="live-update" type="button" phx-click="live-update">Apply synthetic update</button>
      </section>

      <section id="graph-viewport" tabindex="0" aria-label="Synthetic graph viewport" data-reduced-motion={to_string(@reduced_motion)}>
        <div id="graph-content">
          <p>View: {@view}</p>
          <p id="fixture-counts">nodes: {@counts.nodes}, edges: {@counts.edges}, roots: {@counts.roots}</p>
        </div>
      </section>
    </main>
    """
  end
end

defmodule Aiur.BrowserHarness.FixtureAssets do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  @asset_root Path.join(__DIR__, "assets")

  def health(conn, _params), do: send_resp(conn, 200, "synthetic fixture ready")

  def phoenix_html(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_html/phoenix_html.js")
  def phoenix(conn, _params), do: serve_embedded(conn, "/vendor/phoenix/phoenix.js")
  def phoenix_live_view(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")
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

defmodule Aiur.BrowserHarness.FixtureRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    get("/health", Aiur.BrowserHarness.FixtureAssets, :health)
    get("/assets/phoenix_html.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_html)
    get("/assets/phoenix.js", Aiur.BrowserHarness.FixtureAssets, :phoenix)
    get("/assets/phoenix_live_view.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_live_view)
    get("/assets/browser_harness.js", Aiur.BrowserHarness.FixtureAssets, :harness)
    get("/assets/browser_worker.js", Aiur.BrowserHarness.FixtureAssets, :worker)
  end

  scope "/" do
    pipe_through(:browser)

    live("/", Aiur.BrowserHarness.FixtureLive, :index)
  end
end

defmodule Aiur.BrowserHarness.FixtureEndpoint do
  use Phoenix.Endpoint, otp_app: :aiur

  @session_options [store: :cookie, key: "_aiur_browser_harness", signing_salt: "browser-harness"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]], longpoll: false)

  plug(Plug.RequestId)
  plug(Plug.Session, @session_options)
  plug(Aiur.BrowserHarness.FixtureRouter)
end

defmodule Aiur.BrowserHarness.FixtureServer do
  alias Aiur.BrowserHarness.FixtureEndpoint

  @port System.fetch_env!("AIUR_BROWSER_PORT") |> String.to_integer()

  def run do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)

    {:ok, _} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Aiur.BrowserHarness.FixturePubSub}],
        strategy: :one_for_one
      )

    Application.put_env(
      :aiur,
      Aiur.BrowserHarness.FixtureEndpoint,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: @port],
      url: [host: "127.0.0.1", port: @port],
      secret_key_base: String.duplicate("b", 64),
      adapter: Bandit.PhoenixAdapter,
      pubsub_server: Aiur.BrowserHarness.FixturePubSub,
      live_view: [signing_salt: "browser-harness-live-view"],
      check_origin: false
    )

    {:ok, _} = FixtureEndpoint.start_link()
    IO.puts("Aiur browser harness fixture ready at http://127.0.0.1:#{@port}")
    Process.sleep(:infinity)
  end
end

Aiur.BrowserHarness.FixtureServer.run()
