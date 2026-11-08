defmodule AiurWeb.DashboardLive.VoiceTest do
  use Aiur.TestSupport

  import Aiur.ExtensionsTestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Aiur.Orchestrator
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.DashboardLive.VoicePanel

  @endpoint AiurWeb.Endpoint

  defmodule InstalledPanel do
    @moduledoc false
  end

  test "voice conversation pages cap each visible set and compute the page count" do
    workers = for index <- 1..26, do: %{label: "ticket #{index}"}
    first = VoicePanel.page_rows(workers, 0)
    second = VoicePanel.page_rows(workers, 1)

    assert length(first) == 25
    assert second == [%{label: "ticket 26"}]
    assert VoicePanel.page_count(workers) == 2
  end

  test "voice workers include live and stored conversations and hide unavailable tickets" do
    identity = %Aiur.TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      identifier: "42",
      provider_id: "issue-42",
      reason: nil
    }

    live = %{identity: identity, live_conversation: %{generation_handle: "generation"}}
    stored = %{identity: %{identity | identifier: "43", provider_id: "issue-43"}}
    unavailable = %{identity: %{identity | identifier: "44", provider_id: "issue-44"}}

    resolver = fn
      _owner, _repository, "43" -> {:ok, "conv_stored"}
      _, _, _ -> {:error, :not_found}
    end

    catalog = %{status: :ready, snapshot: %{rows: [live, stored, unavailable]}}

    workers = VoicePanel.workers(catalog, history_resolver: resolver)
    assert Enum.map(workers, & &1.label) == ["42", "43"]

    resolved = VoicePanel.resolve(catalog, history_resolver: resolver)
    assert resolved.workers == workers
    assert resolved.hidden == 1
  end

  test "the panel resolves worker availability once per catalog and never on re-render" do
    counter = :counters.new(1, [:atomics])

    resolver = fn _owner, _repository, _identifier ->
      :counters.add(counter, 1, 1)
      {:error, :not_found}
    end

    rows = Enum.map(["41", "42", "43"], &worker_row/1)
    catalog = %{status: :ready, snapshot: %{rows: rows}}
    socket = voice_socket(catalog)
    socket = VoicePanel.assign_workers(socket, history_resolver: resolver)

    assert socket.assigns.voice_workers == []
    assert socket.assigns.voice_hidden_workers == 3
    assert :counters.get(counter, 1) == 3

    # An unchanged catalog reuses the assignment instead of re-reading history.
    socket = VoicePanel.assign_workers(socket, history_resolver: resolver)
    assert :counters.get(counter, 1) == 3

    assigns = panel_assigns(%{units: catalog}) |> Map.merge(Map.take(socket.assigns, [:voice_workers, :voice_hidden_workers]))
    _html = render_component(&VoicePanel.panel/1, Map.to_list(assigns))
    _html = render_component(&VoicePanel.panel/1, Map.to_list(assigns))
    assert :counters.get(counter, 1) == 3

    # A changed catalog resolves again so stored transcripts appear.
    changed = %{catalog | snapshot: %{rows: rows ++ [worker_row("44")]}}
    socket = %{socket | assigns: Map.put(socket.assigns, :payload, %{units: changed})}
    _socket = VoicePanel.assign_workers(socket, history_resolver: resolver)
    assert :counters.get(counter, 1) == 7
  end

  test "worker availability is not resolved outside the voice route" do
    counter = :counters.new(1, [:atomics])

    resolver = fn _owner, _repository, _identifier ->
      :counters.add(counter, 1, 1)
      {:error, :not_found}
    end

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, live_action: :commands, payload: %{units: %{status: :ready, snapshot: %{rows: [worker_row("42")]}}}}
    }

    assert VoicePanel.assign_workers(socket, history_resolver: resolver) == socket
    assert :counters.get(counter, 1) == 0
  end

  test "the panel counts hidden tickets without listing them" do
    hidden = Enum.map(["41", "42"], &worker_row/1)
    catalog = %{status: :ready, snapshot: %{rows: [worker_row("40") | hidden]}}

    assigns =
      panel_assigns(%{units: catalog})
      |> Map.merge(%{voice_workers: [], voice_hidden_workers: 2})

    html = render_component(&VoicePanel.panel/1, Map.to_list(assigns))
    assert html =~ "2 tickets have no conversation."
    assert html =~ ~s(data-hidden-workers="2")
    refute html =~ "ticket 41"
  end

  test "voice page rendering clamps when the openable worker set shrinks" do
    assigns = %{
      payload: %{units: %{status: :ready, snapshot: %{rows: []}}},
      voice_page: 8,
      writable: false,
      voice_capabilities: %{},
      voice_conversation_error: nil,
      now: DateTime.utc_now(),
      conversation_drawer: nil,
      agent_log_modal: nil,
      drafts: %{},
      chat_errors: %{},
      conversation_usage_snapshot: nil,
      conversation_usage_error: nil,
      listener_view: :unavailable,
      listener_feedback: %{},
      listener_receipts: [],
      conversation_row: nil,
      conversation_origin_id: nil
    }

    html = render_component(&VoicePanel.panel/1, Map.to_list(assigns))
    assert html =~ "No workers are listed."
    refute html =~ "Showing 9 of"
  end

  # Voice availability comes from the same registry `/api/v1/capabilities`
  # serves, and a key added mid-session is picked up on the 60 s voice tick
  # rather than only after a failed microphone join.
  test "assigns voice capabilities from the registry at mount and refreshes them on the voice tick" do
    orchestrator_name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    unconfigured = %{state: :unavailable, reason: :not_configured}
    {:ok, reports} = Agent.start_link(fn -> unconfigured end)

    report_fun = fn ->
      stt = Agent.get(reports, & &1)
      %{capabilities: %{"voice.stt" => stt, "voice.tts" => stt, "voice.conversation" => stt, "streamdeck" => %{state: :available}}}
    end

    # Named providers need an explicit private override; atoms otherwise enter shared config.
    start_test_endpoint(snapshot_timeout_ms: 5, capabilities_report_fun: report_fun)
    EndpointStubs.put(orchestrator: orchestrator_name, voice_conversation_panel_module: InstalledPanel)
    {:ok, view, _html} = live(build_conn(), "/commands")
    assert voice_capabilities(view) == %{"voice.stt" => unconfigured, "voice.tts" => unconfigured, "voice.conversation" => unconfigured}

    Agent.update(reports, fn _ -> %{state: :available} end)
    send(view.pid, :elevenlabs_quota_tick)
    _rendered = render(view)
    assert voice_capabilities(view) == %{"voice.stt" => %{state: :available}, "voice.tts" => %{state: :available}, "voice.conversation" => %{state: :available}}
  end

  test "an unreadable registry leaves voice capabilities empty rather than guessing" do
    orchestrator_name = Module.concat(__MODULE__, :FailingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    start_test_endpoint(snapshot_timeout_ms: 5, capabilities_report_fun: fn -> raise "registry unavailable" end)
    EndpointStubs.put(orchestrator: orchestrator_name)
    {:ok, view, _html} = live(build_conn(), "/commands")
    assert voice_capabilities(view) == %{}
  end

  defp voice_capabilities(view), do: :sys.get_state(view.pid).socket.assigns.voice_capabilities

  defp voice_socket(catalog),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, live_action: :voice, payload: %{units: catalog}}}

  defp worker_row(identifier) do
    %{
      identity: %Aiur.TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "owner",
        repository: "repo",
        identifier: identifier,
        provider_id: "issue-#{identifier}",
        reason: nil
      }
    }
  end

  defp panel_assigns(%{} = payload) do
    %{
      payload: payload,
      voice_page: 0,
      writable: false,
      voice_capabilities: %{},
      voice_conversation_error: nil,
      now: DateTime.utc_now(),
      conversation_drawer: nil,
      agent_log_modal: nil,
      drafts: %{},
      chat_errors: %{},
      conversation_usage_snapshot: nil,
      conversation_usage_error: nil,
      listener_view: :unavailable,
      listener_feedback: %{},
      listener_receipts: [],
      conversation_row: nil,
      conversation_origin_id: nil
    }
  end
end
