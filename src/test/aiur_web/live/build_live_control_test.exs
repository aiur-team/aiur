defmodule AiurWeb.BuildLiveControlTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.BuildHome.FixtureSource
  alias Aiur.TestSupport.{EndpointStubs, LiveViewAsync}
  alias AiurWeb.Build.TicketControl

  defmodule Source do
    def subscribe(opts), do: FixtureSource.subscribe(opts)
    def snapshot(opts), do: FixtureSource.snapshot(opts)
    def ticket(id, opts), do: FixtureSource.ticket(id, opts)

    def unit_row(id, opts) do
      send(opts[:test_pid], {:unit_read, id})
      Agent.get(opts[:store], &Map.fetch(&1.rows, id)) |> found()
    end

    defp found(:error), do: {:error, :not_found}
    defp found(result), do: result
  end

  setup do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "NODE-1110", "number" => 1110}, {"aiur-labs", "aiur"}, {"aiur-labs", "aiur"})
    row = %{identity: identity, runtime: %{bucket: :running, work_state: :working}}
    store = start_supervised!({Agent, fn -> %{rows: %{"1110" => row}, capabilities: {:ok, %{unit_control: :confirmed, status: :working, pending_control: nil}}} end})
    test_pid = self()
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, true)

    EndpointStubs.put(
      agent_chat_capabilities_fun: fn id ->
        send(test_pid, {:unit_caps, id})
        Agent.get(store, & &1.capabilities)
      end
    )

    for {key, message, result} <- [{:agent_chat_pause_fun, :unit_pause, {:ok, 8}}, {:agent_chat_resume_fun, :unit_resume, {:ok, :resumed}}] do
      EndpointStubs.put([
        {key,
         fn id ->
           send(test_pid, {message, id})
           result
         end}
      ])
    end

    Application.put_env(:aiur, :build_data_source, {Source, [store: store, dataset: "live", test_pid: self()]})
    %{store: store, row: row}
  end

  defp view(path \\ "/build") do
    {:ok, view, _} = live(build_conn(), path)
    LiveViewAsync.render_when_complete(view)
    view
  end

  defp request(view, params \\ %{id: "1110", action: "pause"}) do
    render_hook(view, "request-unit-control", params)
  end

  defp caps(store, changes) do
    Agent.update(store, &put_in(&1.capabilities, {:ok, Map.merge(%{unit_control: :confirmed, status: :working, pending_control: nil}, changes)}))
  end

  defp row_state(store, state) do
    Agent.update(store, &put_in(&1.rows["1110"].runtime.work_state, state))
  end

  defp lifecycle(view, status, request_id \\ 8, extra \\ %{}) do
    payload = Map.merge(%{tracker_identity: %{identifier: "1110"}, action: :pause, status: status, request_id: request_id, applied_at: DateTime.utc_now()}, extra)
    send(view.pid, {:control_lifecycle, payload})
    render(view)
    payload
  end

  test "invalid params never query capabilities" do
    view = view()

    for params <- [%{}, %{id: 5, action: "pause"}, %{id: "pack:x", action: "pause"}, %{id: "1110", action: "stop"}, %{id: "01", action: "pause"}] do
      request(view, params)
      assert_reply(view, %{"reason" => "invalid_params"})
    end

    refute_received {:unit_caps, _}
  end

  test "read-only at mount and a runtime revocation both prevent owner calls" do
    for revoke_after_mount <- [false, true] do
      Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, revoke_after_mount)
      view = view()
      Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
      request(view)
      assert_reply(view, %{"reason" => "read_only"})
      assert :sys.get_state(view.pid).socket.assigns.writable == false
    end

    refute_received {:unit_read, _}
    refute_received {:unit_caps, _}
    refute_received {:unit_pause, _}
  end

  test "missing rows disable control and chat rather than fabricating eligibility" do
    view = view("/build?ticket=999")
    assert_push_event(view, "build-ticket-control", %{"id" => "999", "control" => nil, "chat" => nil})
    request(view, %{id: "999", action: "pause"})
    assert_reply(view, %{"reason" => "unavailable"})
    refute_received {:unit_caps, _}
  end

  test "fresh capabilities cancel a stale pause and report a concurrent pending request", %{store: store} do
    view = view()
    caps(store, %{status: :paused})
    request(view)
    assert_reply(view, %{"control" => %{"status" => %{"tone" => "warning", "label" => "Unit state changed — pause canceled"}}})
    refute_received {:unit_pause, _}
    caps(store, %{pending_control: 9})
    request(view)
    assert_reply(view, %{"control" => %{"title" => "A pause is already pending", "status" => %{"tone" => "pending"}}})
    refute_received {:unit_pause, _}
  end

  test "debounce, correlation and subscriptions persist after closing until applied", %{store: store} do
    view = view("/build?ticket=1110")
    assert :sys.get_state(view.pid).socket.assigns.control_subscriptions == MapSet.new()
    request(view)
    assert_reply(view, %{"control" => %{"state" => "pending", "status" => %{"tone" => "pending"}}, "by_you_at" => nil} = pending)
    refute Map.has_key?(pending, "upsert")
    assert_received {:unit_pause, "1110"}
    request(view)
    assert_reply(view, %{"control" => %{"state" => "pending"}})
    refute_received {:unit_pause, _}
    assert :sys.get_state(view.pid).socket.assigns.control_subscriptions == MapSet.new(["1110"])
    lifecycle(view, :applied, 9)
    assert :sys.get_state(view.pid).socket.assigns.unit_controls["1110"].status == :requested
    render_hook(view, "build:url", %{ticket: ""})
    row_state(store, :paused)
    payload = lifecycle(view, :applied)
    assert :sys.get_state(view.pid).socket.assigns.control_subscriptions == MapSet.new()
    render_hook(view, "build:url", %{ticket: "1110"})
    expected_at = DateTime.to_unix(payload.applied_at, :millisecond)
    assert_push_event(view, "build-ticket-control", %{"control" => %{"action" => "resume", "status" => %{"tone" => "applied"}}, "by_you_at" => ^expected_at})
  end

  test "expired requests offer retry and stale-generation rejections never report applied" do
    view = view("/build?ticket=1110")
    request(view)
    lifecycle(view, :expired)
    assert_push_event(view, "build-ticket-control", %{"control" => %{"state" => "enabled", "status" => %{"tone" => "error", "retry" => true}}})
    request(view)
    lifecycle(view, :rejected, 8, %{rejection: %{class: :stale_generation}})
    assert_push_event(view, "build-ticket-control", %{"control" => %{"status" => %{"tone" => "warning", "label" => "Unit changed generation — pause canceled"}}})
  end

  test "request-only and unavailable capabilities never dispatch", %{store: store} do
    view = view()
    caps(store, %{unit_control: :request_only})
    request(view)
    assert_reply(view, %{"control" => %{"status" => %{"tone" => "warning"}}})
    Agent.update(store, &%{&1 | capabilities: {:error, :unavailable}})
    request(view)
    assert_reply(view, %{"control" => %{"status" => %{"tone" => "error"}}})
    refute_received {:unit_pause, _}
  end

  test "index changes cancel in-flight intent when a ticket leaves the index", %{store: store} do
    view = view("/build?ticket=1110")
    request(view)
    Agent.update(store, &%{&1 | rows: %{}})
    send(view.pid, {:build_changes, %{now: System.system_time(:millisecond), upsert: [], remove: ["1110"], set: %{}}})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.unit_controls["1110"].status == :state_changed
    assert :sys.get_state(view.pid).socket.assigns.control_subscriptions == MapSet.new()
  end

  test "URL changes seed control without an open-ticket event and return control in ticket replies" do
    view = view()
    render_hook(view, "build:url", %{ticket: "1110"})
    assert_push_event(view, "build-ticket-control", %{"id" => "1110", "control" => %{"state" => "enabled", "action" => "pause"}})
    render_hook(view, "open-ticket", %{id: "1110", loaded: true})
    assert_reply(view, %{"kind" => "ticket", "control" => %{"state" => "enabled"}, "chat" => nil} = reply)
    assert Payload.validate(reply) == :ok
  end

  test "only an own applied pause carries attribution and a resume clears it", %{store: store} do
    row_state(store, :paused)
    view = view("/build?ticket=1110")
    assert_push_event(view, "build-ticket-control", %{"by_you_at" => nil})
    row_state(store, :working)
    request(view)
    row_state(store, :paused)
    payload = lifecycle(view, :applied)
    render_hook(view, "build:url", %{ticket: "1110"})
    at = DateTime.to_unix(payload.applied_at, :millisecond)
    assert_push_event(view, "build-ticket-control", %{"by_you_at" => ^at})
    caps(store, %{status: :paused})
    request(view, %{id: "1110", action: "resume"})
    assert_reply(view, %{"by_you_at" => nil, "control" => %{"action" => "resume"}})
    assert_received {:unit_resume, "1110"}
  end

  # /chat/... redirects back to the modal since C12-T01, so no ticket has a destination until C14-T03.
  test "open-conversation never navigates, even for a live row with an identity" do
    view = view()
    render_hook(view, "open-conversation", %{id: "1110", path: "/evil"})
    assert_reply(view, %{"kind" => "error", "reason" => "unavailable"})
    render_hook(view, "open-conversation", %{id: "pack:1"})
    assert_reply(view, %{"reason" => "invalid_params"})
  end

  test "no control state advertises a conversation route before C14-T03", %{row: row} do
    for writable <- [true, false], state <- [:working, :paused, :ended] do
      assert TicketControl.encode(put_in(row, [:runtime, :work_state], state), nil, writable).chat == nil
    end
  end

  test "disabled causes remain distinct and encoded messages validate", %{row: row} do
    for {state, title} <- [remote_control: "Under Remote Control", retrying: "Unit is retrying", merging: "Unit is merging"] do
      body = TicketControl.encode(Map.put(row, :lifecycle, state), nil, true)
      assert body.control.state == :disabled
      assert body.control.title == title
      message = Map.merge(body, %{v: 1, kind: "control", id: "1110", by_you_at: nil})
      assert Payload.validate(message) == :ok
      assert {:error, _} = Payload.validate(put_in(message, [:control, :state], :invented))
    end
  end

  test "lifecycle published before the owner returns is observed and unsubscribed" do
    view = view("/build?ticket=1110")
    payload = %{tracker_identity: %{identifier: "1110"}, action: :pause, status: :applied, request_id: 8, applied_at: DateTime.utc_now()}

    EndpointStubs.put(
      agent_chat_pause_fun: fn _id ->
        Aiur.AgentPubSub.broadcast_control_lifecycle("1110", payload)
        {:ok, 8}
      end
    )

    :erlang.trace(view.pid, true, [:receive])
    Aiur.AgentPubSub.broadcast_control_lifecycle("1110", payload)
    render(view)
    pid = view.pid
    refute_received {:trace, ^pid, :receive, {:control_lifecycle, ^payload}}
    request(view)
    assert_reply(view, %{"control" => %{"state" => "pending"}})
    render(view)
    assert_received {:trace, ^pid, :receive, {:control_lifecycle, ^payload}}
    assert :sys.get_state(pid).socket.assigns.unit_controls["1110"].status == :applied
    Aiur.AgentPubSub.broadcast_control_lifecycle("1110", payload)
    render(view)
    refute_received {:trace, ^pid, :receive, {:control_lifecycle, ^payload}}
    :erlang.trace(pid, false, [:receive])
  end

  test "a canceled preflight cannot consume an unrelated lifecycle from its temporary subscription" do
    view = view()

    EndpointStubs.put(
      agent_chat_capabilities_fun: fn _id ->
        Aiur.AgentPubSub.broadcast_control_lifecycle("1110", %{tracker_identity: %{identifier: "1110"}, action: :pause, status: :applied, request_id: 9})
        {:error, :unavailable}
      end
    )

    request(view)
    assert_reply(view, %{"control" => %{"status" => %{"tone" => "error"}}})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.unit_controls["1110"].status == :unavailable
    refute_received {:unit_pause, _}
  end
end
