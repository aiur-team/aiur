defmodule AiurWeb.BuildLiveDocTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase

  alias Aiur.BuildOrder.TicketDetailCoordinator
  alias Aiur.TestSupport.BuildHome.{FixtureSource, TicketDocs}
  alias Aiur.TestSupport.{EndpointStubs, LiveViewAsync}

  defmodule Source do
    defdelegate subscribe(opts), to: FixtureSource
    defdelegate snapshot(opts), to: FixtureSource
    defdelegate ticket(id, opts), to: FixtureSource

    def ticket_doc_identity(id, opts) do
      send(opts[:test_pid], {:identity_read, id})

      case opts[:identity_mode] do
        :none -> :no_identity
        :raise -> raise "identity source down"
        _ -> FixtureSource.ticket_doc_identity(id, opts)
      end
    end
  end

  setup do
    owner = self()

    EndpointStubs.put(
      ticket_detail_subscribe_fun: fn identity ->
        send(owner, {:doc_action, :subscribe, identity})
        Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCoordinator.topic(identity))
      end,
      ticket_detail_unsubscribe_fun: fn identity ->
        send(owner, {:doc_action, :unsubscribe, identity})
        Phoenix.PubSub.unsubscribe(Aiur.PubSub, TicketDetailCoordinator.topic(identity))
      end,
      ticket_detail_request_fun: fn identity ->
        send(owner, {:doc_action, :request, identity})
        TicketDocs.request(identity)
      end
    )

    :ok
  end

  defp open_view(opts \\ []) do
    Application.put_env(:aiur, :build_data_source, {Source, Keyword.merge([test_pid: self(), dataset: "live"], opts)})
    {:ok, view, _html} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    view
  end

  defp row(index \\ 0), do: Enum.at(data()["sections"]["plan"], index)
  defp identity(id), do: elem(FixtureSource.ticket_doc_identity(id, dataset: "live"), 1)

  defp open_doc(view, id) do
    render_hook(view, "ticket-doc", %{id: id})
    assert_reply(view, %{"kind" => "doc", "id" => ^id, "state" => "available"})
    assert_received {:identity_read, ^id}
    expected = identity(id)
    assert_received {:doc_action, first, ^expected}
    assert first == :subscribe
    assert_received {:doc_action, second, ^expected}
    assert second == :request
    expected
  end

  test "doc reads subscribe before request and remain available in a read-only mount" do
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    view = open_view()
    id = row()["id"]
    selected = open_doc(view, id)
    assert :sys.get_state(view.pid).socket.assigns.doc_identity == selected
    assert :sys.get_state(view.pid).socket.assigns.doc_id == id
  end

  test "switching and closing unsubscribe the exact prior identity" do
    view = open_view()
    first = open_doc(view, row()["id"])
    second_id = row(1)["id"]
    render_hook(view, "ticket-doc", %{id: second_id})
    assert_reply(view, %{"id" => ^second_id, "state" => "available"})
    second = identity(second_id)
    assert_received {:doc_action, action, selected}
    assert {action, selected} == {:unsubscribe, first}
    assert_received {:doc_action, action, selected}
    assert {action, selected} == {:subscribe, second}
    assert_received {:doc_action, action, selected}
    assert {action, selected} == {:request, second}
    render_hook(view, "ticket-doc-close", %{})
    assert_received {:doc_action, :unsubscribe, ^second}
    assert :sys.get_state(view.pid).socket.assigns.doc_identity == nil
    assert :sys.get_state(view.pid).socket.assigns.doc_id == nil
    {:ok, old_state} = TicketDocs.request(second)
    send(view.pid, {:ticket_detail_updated, old_state})
    render(view)
    refute_push_event(view, "build-ticket-doc", _)
  end

  test "matching updates push rendered body while other identities are ignored" do
    view = open_view()
    id = row()["id"]
    selected = open_doc(view, id)
    {:ok, other} = TicketDocs.request(identity(row(1)["id"]))
    send(view.pid, {:ticket_detail_updated, other})
    render(view)
    refute_push_event(view, "build-ticket-doc", _)
    {:ok, state} = TicketDocs.request(selected)
    updated = put_in(state.detail.description, "Updated **issue** body")
    Phoenix.PubSub.broadcast(Aiur.PubSub, TicketDetailCoordinator.topic(selected), {:ticket_detail_updated, updated})
    assert_push_event(view, "build-ticket-doc", %{"id" => ^id, "state" => "available", "body_html" => html})
    assert html == "<p>Updated <strong>issue</strong> body</p>"
  end

  test "coordinator reset re-requests only the currently open doc" do
    view = open_view()
    selected = open_doc(view, row()["id"])
    Phoenix.PubSub.broadcast(Aiur.PubSub, TicketDetailCoordinator.reset_topic(), {:ticket_detail_coordinator_reset, 2})
    assert_push_event(view, "build-ticket-doc", %{"state" => "available"})
    assert_received {:doc_action, :request, ^selected}
    refute_received {:doc_action, :subscribe, _}
    render_hook(view, "ticket-doc-close", %{})
    assert_received {:doc_action, :unsubscribe, ^selected}
    send(view.pid, {:ticket_detail_coordinator_reset, 3})
    render(view)
    refute_received {:doc_action, :request, _}
    refute_push_event(view, "build-ticket-doc", _)
  end

  test "invalid ids leave the open doc unchanged without reading the source" do
    view = open_view()
    selected = open_doc(view, row()["id"])

    for params <- [%{}, %{id: 42}, %{id: %{}}, %{id: "0"}, %{id: "042"}, %{id: "-42"}, %{id: "12345678901"}, %{id: "42\n"}] do
      render_hook(view, "ticket-doc", params)
      assert_reply(view, %{"kind" => "error", "reason" => "invalid_params"})
      assert :sys.get_state(view.pid).socket.assigns.doc_identity == selected
      refute_received {:identity_read, _}
      refute_received {:doc_action, _, _}
    end
  end

  test "request exceptions and exits become unavailable doc replies without crashing" do
    for fun <- [fn _ -> raise "detail source down" end, fn _ -> exit(:detail_source_down) end] do
      EndpointStubs.put(ticket_detail_request_fun: fun)
      view = open_view()
      render_hook(view, "ticket-doc", %{id: row()["id"]})
      assert_reply(view, %{"kind" => "doc", "state" => "unavailable", "body_html" => nil})
      assert Process.alive?(view.pid)
    end
  end

  test "unknown identity and identity-source exceptions have explicit doc states" do
    for {mode, expected} <- [{:none, "identity_unknown"}, {:raise, "unavailable"}] do
      view = open_view(identity_mode: mode)
      render_hook(view, "ticket-doc", %{id: row()["id"]})
      assert_reply(view, %{"kind" => "doc", "state" => ^expected, "body_html" => nil})
      refute_received {:doc_action, _, _}
      assert Process.alive?(view.pid)
    end
  end

  # Future regression guard; not counted as coverage of the new document producer.
  test "opening a ticket does not request its doc" do
    view = open_view()
    id = row()["id"]
    render_hook(view, "open-ticket", %{id: id, loaded: true})
    assert_reply(view, %{"kind" => "ticket"})
    refute_received {:identity_read, _}
    refute_received {:doc_action, _, _}
    assert :sys.get_state(view.pid).socket.assigns.doc_id == nil
  end
end
