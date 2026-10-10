Code.require_file("../support/build_home/fixture_source.ex", __DIR__)
Code.require_file("../support/browser_harness/fixtures.ex", __DIR__)
Code.require_file("../support/browser_harness/fixture_controls.ex", __DIR__)
Code.require_file("../support/browser_harness/build_control.ex", __DIR__)
Code.require_file("../support/browser_harness/palette_layout.ex", __DIR__)
Code.require_file("../support/browser_harness/models_panel_live.ex", __DIR__)

for file <- ~w(
      route_shell_live graph_live ticket_context_live units_live_data units_live
      support build_order_source meters_live
    ) do
  Code.require_file("fixture/#{file}.exs", __DIR__)
end

defmodule Aiur.BrowserHarness.FixtureRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias Aiur.BrowserHarness.FixtureAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :fixture_access do
    plug(:require_fixture_access)
  end

  pipeline :fixture_asset_access do
    plug(:require_fixture_or_dashboard_access)
  end

  scope "/" do
    get("/health", Aiur.BrowserHarness.FixtureAssets, :health)
    get("/assets/phoenix_html.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_html)
    get("/assets/phoenix.js", Aiur.BrowserHarness.FixtureAssets, :phoenix)
    get("/assets/phoenix_live_view.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_live_view)
    get("/assets/ticket-context-dialog-hook.js", Aiur.BrowserHarness.FixtureAssets, :ticket_context_dialog_hook)
    get("/assets/build-order-grid-hook.js", Aiur.BrowserHarness.FixtureAssets, :build_order_grid_hook)
    get("/assets/time-brush-hook.js", Aiur.BrowserHarness.FixtureAssets, :time_brush_hook)
    get("/assets/streamdeck-emulator-hook.js", Aiur.BrowserHarness.FixtureAssets, :streamdeck_emulator_hook)
    get("/assets/sortable-table-hook.js", Aiur.BrowserHarness.FixtureAssets, :sortable_table_hook)
    get("/assets/browser_harness.js", Aiur.BrowserHarness.FixtureAssets, :harness)
    get("/assets/browser_worker.js", Aiur.BrowserHarness.FixtureAssets, :worker)
  end

  scope "/" do
    pipe_through(:browser)

    get("/auth/:mode", Aiur.BrowserHarness.FixtureAuth, :authenticate)
    get("/build-fixture/:dataset", Aiur.BrowserHarness.FixtureBuildDataset, :configure)
    get("/build-control/:action", Aiur.BrowserHarness.FixtureBuildControl, :configure)
    get("/streamdeck-control/:mode", Aiur.BrowserHarness.FixtureStreamdeckControl, :configure)
    get("/build-queue-control/:state", Aiur.BrowserHarness.BuildQueueFixture, :configure)
  end

  scope "/" do
    pipe_through([:browser, :fixture_access])

    live_session :production_root, root_layout: {AiurWeb.Layouts, :root} do
      live("/palette-probe", Aiur.BrowserHarness.PaletteProbeLive, :index)
    end

    live("/fixture", Aiur.BrowserHarness.FixtureLive, :index)
    live("/ticket-context", Aiur.BrowserHarness.TicketContextLive, :index)
    live("/units", Aiur.BrowserHarness.UnitsLive, :index)
    live("/provider-meters", Aiur.BrowserHarness.ProviderMetersLive, :index)
    live("/meter-row", Aiur.BrowserHarness.MeterRowLive, :index)
    live("/models-panel", Aiur.BrowserHarness.ModelsPanelLive, :index)
    live("/quota-panel", Aiur.BrowserHarness.QuotaPanelLive, :index)
    live("/", Aiur.BrowserHarness.RouteShellLive, :index)
    live("/commands", Aiur.BrowserHarness.RouteShellLive, :decisions)
    live("/commands/:decision_id", Aiur.BrowserHarness.RouteShellLive, :decision)
  end

  scope "/" do
    pipe_through([:browser, :fixture_asset_access])

    get("/dashboard.css", AiurWeb.StaticAssetController, :dashboard_css)
    get("/aiur-logo.png", AiurWeb.StaticAssetController, :aiur_logo)
  end

  # Route vendor assets through production to exercise release authentication and content-addressed paths.
  scope "/" do
    forward("/", AiurWeb.Router)
  end

  defp require_fixture_access(conn, opts), do: FixtureAuth.require_access(conn, opts)

  defp require_fixture_or_dashboard_access(conn, opts) do
    if Plug.Conn.get_session(conn, "fixture_access") in ~w(read_only writable),
      do: conn,
      else: AiurWeb.Router.dashboard_basic_auth(conn, opts)
  end
end

defmodule Aiur.BrowserHarness.FixtureEndpoint do
  use Phoenix.Endpoint, otp_app: :aiur

  @session_options [store: :cookie, key: "_aiur_browser_harness", signing_salt: "browser-harness", http_only: true, same_site: "Lax"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]], longpoll: false)

  socket("/voice", AiurWeb.VoiceSocket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 400_000],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.revalidated_static_paths() -- ["dashboard.css"],
    cache_control_for_etags: "private, max-age=0, must-revalidate",
    cache_control_for_vsn_requests: "private, max-age=0, must-revalidate"
  )

  plug(Plug.Static,
    at: "/",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.long_lived_static_paths(),
    cache_control_for_etags: "public, max-age=31536000",
    cache_control_for_vsn_requests: "public, max-age=31536000"
  )

  plug(Plug.Static,
    at: "/provider-assets",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.provider_asset_paths(),
    cache_control_for_etags: "private, max-age=0, must-revalidate",
    cache_control_for_vsn_requests: "private, max-age=0, must-revalidate"
  )

  plug(Plug.RequestId)
  plug(Plug.Session, @session_options)
  plug(Aiur.BrowserHarness.FixtureRouter)
end

defmodule Aiur.BrowserHarness.FixtureServer do
  alias Aiur.BrowserHarness.{FixtureEndpoint, VoiceSTT}
  alias Aiur.IssueLog

  @port System.fetch_env!("AIUR_BROWSER_PORT") |> String.to_integer()

  def run do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)

    System.put_env("AIUR_DASHBOARD_USERNAME", "browser_fixture")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "browser_fixture_password")
    Application.put_env(:aiur, :workflow_file_path, Path.expand("../fixtures/test.yaml", __DIR__))
    Application.put_env(:aiur, :build_data_source, Aiur.TestSupport.BuildHome.FixtureSource)
    Application.put_env(:aiur, :build_order_data_source, Aiur.BrowserHarness.BuildOrderDataSource)
    configure_forwarded_dashboard()

    {:ok, _} =
      Supervisor.start_link(
        [
          Supervisor.child_spec(
            {Phoenix.PubSub, name: Aiur.BrowserHarness.FixturePubSub},
            id: Aiur.BrowserHarness.FixturePubSub
          ),
          Supervisor.child_spec({Phoenix.PubSub, name: Aiur.PubSub}, id: Aiur.PubSub),
          {AiurWeb.Endpoint, []},
          AiurWeb.FinancialDataAccess.Generation,
          AiurWeb.VoiceSessionLimiter
        ],
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

  def set_streamdeck_snapshot_identities(identifiers) when is_list(identifiers) do
    :persistent_term.put({__MODULE__, :streamdeck_snapshot_identities}, Enum.map(identifiers, &to_string/1))
  end

  @doc """
  Fixture stand-in for `AgentChat.pause/1` and `AgentChat.resume/1`.
  The emulator's key press is only meaningful if the fleet it renders actually
  moves, so the fixture records the operator pause and republishes the fleet.
  The next projection buckets the agent as `:paused`, exactly as the real
  orchestrator snapshot would.
  """
  def streamdeck_pause(identifier), do: {:ok, set_streamdeck_paused(identifier, true)}

  def streamdeck_resume(identifier), do: {:ok, set_streamdeck_paused(identifier, false)}

  @doc "Drops every recorded operator pause so a spec starts from the seeded fleet."
  def reset_streamdeck_pauses do
    :persistent_term.put({__MODULE__, :streamdeck_paused}, MapSet.new())
    Phoenix.PubSub.broadcast(Aiur.PubSub, "streamdeck:fixture", :streamdeck_fixture_fleet_changed)
    :ok
  end

  defp set_streamdeck_paused(identifier, paused?) do
    identifier = to_string(identifier)
    current = :persistent_term.get({__MODULE__, :streamdeck_paused}, MapSet.new())
    updated = if paused?, do: MapSet.put(current, identifier), else: MapSet.delete(current, identifier)

    :persistent_term.put({__MODULE__, :streamdeck_paused}, updated)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "streamdeck:fixture", :streamdeck_fixture_fleet_changed)

    identifier
  end

  defp streamdeck_paused?(identifier) do
    MapSet.member?(:persistent_term.get({__MODULE__, :streamdeck_paused}, MapSet.new()), to_string(identifier))
  end

  def streamdeck_snapshot do
    case :persistent_term.get({__MODULE__, :streamdeck_snapshot_identities}, nil) do
      identifiers when is_list(identifiers) ->
        streamdeck_snapshot(identifiers)

      _ ->
        # The canonical bucket order puts the alert agent first, so the LiveView
        # initially focuses 1331; seed its durable feed so the production
        # AgentEventFeed path has real content to project in logs mode.
        write_feed_if_missing("1331")
        # The operator flow drives one agent through cmd and logs, so the
        # running agent it controls needs a durable feed of its own.
        write_feed_if_missing("1352")

        %{
          running: [streamdeck_agent("1352", "Fixture running", "codex", progress_percent: 0)],
          retrying: [streamdeck_agent("1338", "Fixture stuck", "codex", work_state: :error, progress_percent: 100)],
          idle: [
            streamdeck_agent("1345", "Fixture paused", "claude", work_state: :paused),
            streamdeck_agent("1350", "Fixture queued", "codex", waiting_reason: :waiting_for_dependency),
            streamdeck_agent("1331", "Fixture alert", "claude", open_decision_count: 1),
            streamdeck_agent("1360", "Fixture extra 1", "codex"),
            streamdeck_agent("1361", "Fixture extra 2", "codex"),
            streamdeck_agent("1362", "Fixture extra 3", "codex"),
            streamdeck_agent("1363", "Fixture extra 4", "codex"),
            streamdeck_agent("1366", "Fixture extra 5", "codex"),
            streamdeck_agent("1367", "Fixture extra 6", "codex"),
            streamdeck_agent("1370", "Fixture extra 7", "codex"),
            streamdeck_agent("1371", "Fixture extra 8", "codex"),
            streamdeck_agent("1372", "Fixture extra 9", "codex"),
            streamdeck_agent("1373", "Fixture extra 10", "codex"),
            streamdeck_agent("1374", "Fixture extra 11", "codex"),
            streamdeck_agent("1375", "Fixture extra 12", "codex"),
            streamdeck_agent("1376", "Fixture extra 13", "codex"),
            streamdeck_agent("1377", "Fixture extra 14", "codex")
          ]
        }
    end
  end

  defp streamdeck_snapshot(identifiers) when is_list(identifiers) do
    agents =
      Enum.map(identifiers, fn identifier ->
        streamdeck_agent(identifier, "Unit #{identifier}", "codex")
      end)

    if agents != [], do: write_feed_if_missing(hd(identifiers))

    %{running: Enum.take(agents, 1), retrying: [], idle: Enum.drop(agents, 1)}
  end

  def streamdeck_provider_meters do
    %{
      "claude" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 30, "remaining" => "22m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 47, "resets_at" => "2026-08-13T18:00:00Z", "freshness" => "fresh"}
        }
      },
      "codex" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 50, "remaining" => "1h", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 75, "resets_at" => "2026-08-14T20:00:00Z", "freshness" => "fresh"}
        }
      }
    }
  end

  # Seeded once per harness boot, not once per disk lifetime. `File.exists?/1`
  # alone made the feed sticky: a local run reused whatever a previous run had
  # written, so editing this fixture silently had no effect on the tests that
  # read it. The snapshot callbacks fire on every poll, hence the guard.
  defp write_feed_if_missing(identifier) when is_binary(identifier) do
    key = {__MODULE__, :seeded_feed, identifier}

    if :persistent_term.get(key, false) do
      :ok
    else
      write_feed(IssueLog.transcript_path(identifier))
      write_bus_feed(IssueLog.event_log_path(identifier), identifier)
      :persistent_term.put(key, true)
    end
  end

  # The shared event bus, which is what the logs surface's keys come from. The
  # transcript written above is the detail underneath them, not a source of
  # keys: grouping transcript turns into events is exactly the defect the logs
  # rebuild removed, so a fixture that only wrote a transcript would exercise a
  # surface with no events on it at all.
  #
  # Kinds are chosen to cover every direction the badge mapping produces:
  # `self` -> AGENT, `consumed` -> CONSUME, `emit_alert` -> SYSTEM, `emit` ->
  # EMIT. INFO is the origin anchor's, which every projection synthesises.
  defp write_bus_feed(path, identifier) do
    File.mkdir_p!(Path.dirname(path))
    # On the *last* four events, because the eight-key window opens at the
    # newest end: kinds placed on events 1..4 would sit off-screen behind the
    # origin anchor and no spec could read their badges without scrolling first.
    kinds = %{7 => "self", 8 => "consumed", 9 => "emit_alert", 10 => "emit"}

    lines =
      Enum.map(1..10, fn index ->
        kind = Map.get(kinds, index, "emit")
        minute = String.pad_leading(to_string(index), 2, "0")
        "2026-08-02T00:#{minute}:00Z [event:#{kind}] id=#{index} ticket.#{identifier}.pr.opened: event-#{index}"
      end)

    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp write_feed(path) do
    File.mkdir_p!(Path.dirname(path))

    # A mix of roles, not ten assistants: the roles are what `AgentEventFeed`
    # maps onto the five Stream Deck direction badges, so a single-role feed
    # would let a log key assert its badge without the mapping being wired at
    # all. Events 1..5 cover AGENT, CONSUME, SYSTEM, INFO and EMIT in order.
    roles = %{1 => "assistant", 2 => "user", 3 => "system", 4 => "reasoning", 5 => "command"}

    events =
      Enum.map(10..1, fn index ->
        %{
          "role" => Map.get(roles, index, "assistant"),
          "body" => "event-#{index}",
          # After every bus event, so the transcript sits under the newest one
          # rather than under the origin. `read_tail/2` treats the last line as
          # newest, and this file is written 10-first, so index 1 is newest.
          "timestamp" => "2026-08-02T00:#{String.pad_leading(to_string(31 - index), 2, "0")}:00Z",
          "msg_id" => nil,
          "sequence" => index,
          "turn_id" => "fixture-#{index}",
          "payload" => nil
        }
      end)

    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp configure_forwarded_dashboard do
    config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        dashboard_auth_required: true,
        # Stays read-only by default so incidental key presses in other specs
        # cannot mutate the shared fixture fleet. The operator-flow spec opts its
        # own fixture server in through `/streamdeck-control/writable`.
        dashboard_writable: false,
        control_center_cache: false,
        snapshot_timeout_ms: 100,
        streamdeck_fixture_fleet: true,
        streamdeck_snapshot_fun: &__MODULE__.streamdeck_snapshot/0,
        streamdeck_provider_meters_fun: &__MODULE__.streamdeck_provider_meters/0,
        agent_chat_pause_fun: &__MODULE__.streamdeck_pause/1,
        agent_chat_resume_fun: &__MODULE__.streamdeck_resume/1,
        voice_stt_start_fun: fn socket ->
          case VoiceSTT.start_link(socket.channel_pid) do
            {:ok, pid} -> {:ok, %{pid: pid}}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end,
        voice_tts_start_fun: fn socket, text ->
          {:ok, pid} =
            Task.start(fn ->
              if text == "Voice reply from the agent." do
                send(socket.channel_pid, {:elevenlabs_audio, :chunk, <<0, 0, 255, 127, 0, 0, 1, 128>>})
                send(socket.channel_pid, {:elevenlabs_audio, :done})
              else
                send(socket.channel_pid, {:elevenlabs_audio, :error, "fixture received an incomplete reply"})
              end
            end)

          {:ok, pid}
        end
      )
      |> Keyword.delete(:streamdeck_logs_fun)

    Application.put_env(:aiur, AiurWeb.Endpoint, config)
  end

  defp streamdeck_agent(identifier, title, backend, attrs \\ []) do
    %{
      identifier: identifier,
      title: title,
      backend: backend,
      work_state: :working,
      open_decision_count: 0,
      waiting_reason: :active,
      tracker_paused: false,
      progress_percent: 50,
      priority: nil
    }
    |> Map.merge(Map.new(attrs))
    |> apply_operator_pause(identifier)
  end

  # An operator pause outranks the seeded work state so a key press moves the
  # agent into the paused bucket without the fixture restating every field.
  defp apply_operator_pause(agent, identifier) do
    if streamdeck_paused?(identifier), do: Map.put(agent, :tracker_paused, true), else: agent
  end
end

Aiur.BrowserHarness.FixtureServer.run()
