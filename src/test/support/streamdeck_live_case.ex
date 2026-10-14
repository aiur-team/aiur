defmodule AiurWeb.StreamdeckLiveCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  import Phoenix.LiveViewTest

  alias Aiur.{CodingAgent, IssueLog}
  alias Aiur.TestSupport.AwaitingCommands
  alias AiurWeb.Endpoint

  using do
    quote do
      use Aiur.TestSupport

      import Phoenix.ConnTest, except: [build_conn: 0]
      import Phoenix.LiveViewTest
      import AiurWeb.StreamdeckLiveCase

      alias Aiur.{AgentEvents, AgentPubSub, CodingAgent, IssueLog}
      alias Aiur.TestSupport.AwaitingCommands
      alias AiurWeb.Endpoint

      @endpoint Endpoint

      setup context do
        AiurWeb.StreamdeckLiveCase.setup_streamdeck(context)
      end
    end
  end

  def setup_streamdeck(context) do
    test_pid = self()
    {:ok, snapshot_agent} = Agent.start_link(fn -> fixture_snapshot() end)
    {:ok, meter_agent} = Agent.start_link(fn -> fixture_provider_meters() end)
    previous_endpoint = Application.get_env(:aiur, Endpoint)

    endpoint_config =
      :aiur
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_writable: true,
        dashboard_auth_required: false,
        streamdeck_transcript_flush_ms: 1,
        streamdeck_snapshot_fun: fn -> Agent.get(snapshot_agent, & &1) end,
        streamdeck_provider_meters_fun: fn -> Agent.get(meter_agent, & &1) end,
        streamdeck_logs_fun: &fixture_logs/1,
        streamdeck_commands_fun: &fixture_commands/2,
        # The control seams stand in for the orchestrator: they settle the
        # shared snapshot the same way a real control call would, so the view
        # can only render the new state by re-reading that snapshot.
        #
        # There is no prioritize seam here any more. The deck's agent view lost
        # its priority key, so the view has no path to `AgentChat.prioritize/1`
        # left to stub. Orchestrator priority is still covered where it lives:
        # `Aiur.Orchestrator.PriorityControl` and the control agreement test.
        agent_chat_pause_fun: fn identifier ->
          send(test_pid, {:streamdeck_pause, identifier})
          Agent.update(snapshot_agent, &put_fixture_agent(&1, identifier, work_state: :paused))
          {:ok, 1}
        end,
        agent_chat_resume_fun: fn identifier ->
          send(test_pid, {:streamdeck_resume, identifier})
          Agent.update(snapshot_agent, &put_fixture_agent(&1, identifier, work_state: :working))
          {:ok, :resumed}
        end
      )
      |> Keyword.merge(awaiting_commands_config(context))

    Application.put_env(:aiur, Endpoint, endpoint_config)
    Aiur.TestSupport.start_owned_endpoint!()

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, previous_endpoint)
      Aiur.TestSupport.safe_stop(snapshot_agent)
      Aiur.TestSupport.safe_stop(meter_agent)
    end)

    {:ok, snapshot_agent: snapshot_agent, meter_agent: meter_agent}
  end

  def rendered_command_keys(html) do
    ~r/data-streamdeck-command="([a-z]+)".*?<span class="sd-cmd-label">([^<]*)<\/span>\s*<span class="sd-cmd-sub">([^<]*)<\/span>/s
    |> Regex.scan(html)
    |> Enum.map(fn [_match, command, label, sub] -> {command, label, sub} end)
  end

  def fixture_snapshot do
    %{
      running: [fixture_agent("1352", "Live running", "codex", priority: 1)],
      retrying: [],
      idle: [
        fixture_agent("1345", "Live paused", "claude", work_state: :paused),
        fixture_agent("1350", "Live queued", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1360", "Extra one", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1361", "Extra two", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1362", "Extra three", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1363", "Extra four", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1366", "Extra five", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1367", "Extra six", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1370", "Extra seven", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1371", "Extra eight", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1372", "Extra nine", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1373", "Extra ten", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1374", "Extra eleven", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1375", "Extra twelve", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1376", "Extra thirteen", "codex", waiting_reason: :waiting_for_dependency),
        fixture_agent("1377", "Extra fourteen", "codex", waiting_reason: :waiting_for_dependency)
      ]
    }
  end

  def put_fixture_agent(snapshot, identifier, attrs) do
    Map.new(snapshot, fn {bucket, entries} ->
      {bucket, Enum.map(entries, fn entry -> if entry.identifier == identifier, do: Map.merge(entry, Map.new(attrs)), else: entry end)}
    end)
  end

  def fixture_agent(identifier, title, backend, attrs \\ []) do
    Map.merge(
      %{
        identifier: identifier,
        title: title,
        backend: backend,
        work_state: :working,
        open_decision_count: 0,
        waiting_reason: :active,
        tracker_paused: false,
        progress_percent: 50,
        priority: nil,
        blocked_by: [%{id: "missing-upstream"}]
      },
      Map.new(attrs)
    )
  end

  def fixture_provider_meters do
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

  def configured_providers do
    families =
      Aiur.Config.agent_backend_configs()
      |> CodingAgent.dispatchable_backends()
      |> Enum.map(&CodingAgent.family_for/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    Enum.filter(CodingAgent.provider_descriptors(), &MapSet.member?(families, &1.provider))
  end

  # The emulator's injected feed stands in for both real sources: ten
  # shared-event-bus rows, which are the deck's keys, and one transcript line
  # under each, which is the detail a key jumps into. A bare list would now be
  # read as transcript only and project no event keys at all.
  def fixture_logs(_identifier) do
    %{
      events: Enum.map(1..10, &fixture_bus_event/1),
      # `AgentEventFeed.list/2` hands the transcript back newest first; the
      # projection is what reverses it into reading order.
      transcript: Enum.map(10..1//-1, &feed_entry("line-#{&1}", fixture_stamp(&1, 30)))
    }
  end

  def fixture_bus_event(index) do
    %{
      type: "event",
      id: index,
      kind: "self",
      topic: "ticket.1352.agent.progress",
      badge: Aiur.AgentEventFeed.badge_for_kind("self"),
      label: "event-#{index}",
      body: "",
      timestamp: fixture_stamp(index, 0)
    }
  end

  # The Commands fixture mirrors the allowlisted page the channel projects: one
  # answerable Command with options and one completed read-only Command. The
  # browser surface reads it the same way the physical deck would.
  def fixture_commands(identifier, _cursor) when identifier in ["1352"] do
    {:ok,
     %{
       "items" => [
         %{
           "decision_id" => "dec-open-1",
           "version" => 1,
           "question" => "Ship the change?",
           "status" => "open",
           "context" => %{"short" => "The checks are green."},
           "options" => [
             %{"id" => "ship", "label" => "Ship it", "description" => "Merge and deploy now."},
             %{"id" => "wait", "label" => "Wait", "description" => "Hold until tomorrow."}
           ]
         },
         %{
           "decision_id" => "dec-done-1",
           "version" => 1,
           "question" => "Rotate the key?",
           "status" => "decided",
           "options" => []
         }
       ],
       "next_cursor" => nil,
       "has_next" => false,
       "total" => 2,
       "partial" => false,
       "unavailable" => false
     }}
  end

  def fixture_commands(_identifier, _cursor), do: {:ok, %{"items" => [], "unavailable" => false}}

  def feed_entry(body, timestamp) do
    %{
      type: "message",
      badge: "AGENT",
      role: "assistant",
      body: body,
      timestamp: timestamp
    }
  end

  def fixture_stamp(minute, second) do
    "2026-08-02T00:#{String.pad_leading(to_string(minute), 2, "0")}:#{String.pad_leading(to_string(second), 2, "0")}Z"
  end

  def feed_event(role, body, turn_id, opts \\ [])

  def feed_event(role, body, turn_id, payload) when is_map(payload),
    do: feed_event(role, body, turn_id, payload: payload)

  def feed_event(role, body, turn_id, opts) when is_list(opts) do
    %{
      "role" => role,
      "body" => body,
      "timestamp" => Keyword.get(opts, :timestamp, "2026-08-02T00:00:00Z"),
      "msg_id" => nil,
      "sequence" => 1,
      "turn_id" => turn_id,
      "payload" => Keyword.get(opts, :payload)
    }
  end

  def write_feed(identifier, events) do
    path = IssueLog.transcript_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  # The shared event bus is a second, separate source from the transcript, so a
  # production-feed test that wants real event keys has to write real
  # `[event:<kind>]` rows. `with_production_feed/1` removes them again, because
  # one of these tests rewrites the log from a Task, which cannot register an
  # `on_exit`, and the whole suite shares the "1352" identifier.
  def write_event_log(identifier, lines) do
    path = IssueLog.event_log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  def event_line(id, kind, topic, summary, timestamp) do
    "#{timestamp} [event:#{kind}] id=#{id} #{topic}: #{summary}"
  end

  def with_production_feed(fun) do
    previous_endpoint_value = Endpoint.config(:streamdeck_logs_fun)
    previous_endpoint_config = Application.get_env(:aiur, Endpoint, [])

    Phoenix.Config.put(Endpoint, :streamdeck_logs_fun, nil)
    Application.put_env(:aiur, Endpoint, Keyword.put(previous_endpoint_config, :streamdeck_logs_fun, nil))

    try do
      fun.()
    after
      Enum.each(~w(1352 1345), &File.rm(IssueLog.event_log_path(&1)))
      Application.put_env(:aiur, Endpoint, previous_endpoint_config)
      Phoenix.Config.put(Endpoint, :streamdeck_logs_fun, previous_endpoint_value)
    end
  end

  # The touch strip is the transcript surface in logs mode, so its contents run
  # from the `#sd-screen` tag to the well that follows it. A non-greedy
  # `</div>` would stop at the first strip entry.
  def strip(html) do
    case Regex.run(~r{id="sd-screen".*?class="sd-well"}s, html) do
      [pane | _] -> pane
      nil -> flunk("missing #sd-screen touch strip")
    end
  end

  def strip_offset(html) do
    case Regex.run(~r/id="sd-screen"[^>]*?data-transcript-offset="(\d+)"/s, html) do
      [_full, offset] -> String.to_integer(offset)
      nil -> flunk("#sd-screen carries no data-transcript-offset")
    end
  end

  def log_pane(html, id) do
    case Regex.run(~r{<div id="#{id}"[^>]*>.*?</div>}s, html) do
      [pane | _] -> pane
      nil -> flunk("missing log pane ##{id}")
    end
  end

  def streamdeck_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  def eventually(fun, attempts \\ 30)
  def eventually(_fun, 0), do: false

  def eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  def enter_logs(view, identifier \\ "1352") do
    render_hook(view, "key-press", %{"identifier" => identifier})
    render_click(view, "command-press", %{"command" => "logs"})
  end

  def slot_identifiers(html) do
    Regex.scan(~r/data-streamdeck-identifier="([^"]+)"/, html, capture: :all_but_first)
    |> List.flatten()
  end

  def command_key(html, command) do
    [key] = Regex.run(~r{<button[^>]*data-streamdeck-command="#{command}".*?</button>}s, html)
    key
  end

  def command_icon(html, command) do
    [_key, icon] = Regex.run(~r/data-streamdeck-icon="([^"]+)"/, command_key(html, command))
    icon
  end

  def fleet_snapshot(total) do
    agents = for index <- 1..total, do: fixture_agent("fleet-#{index}", "Fleet #{index}", "codex")
    %{running: [hd(agents)], retrying: [], idle: tl(agents)}
  end

  # Dashboard routes are behind the FinancialDataAccess plug, which challenges
  # any request once credentials are configured (regardless of `dashboard_auth_required`).
  # test_helper configures credentials globally, so every Stream Deck render test must
  # present them.
  def build_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header(
      "authorization",
      "Basic " <> Base.encode64("operator:test-dashboard-secret")
    )
  end

  # --- awaiting-Commands banner ---------------------------------------------

  def awaiting_commands_config(context) do
    case context[:awaiting_commands] do
      nil -> []
      counts -> [decision_store: AwaitingCommands.start(counts)]
    end
  end
end
