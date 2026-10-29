defmodule AiurWeb.BuildLiveQueueAddTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.{EndpointStubs, LiveViewAsync}
  alias AiurWeb.Endpoint

  defp open_view(writable \\ true) do
    Phoenix.Config.put(Endpoint, :dashboard_writable, writable)
    {:ok, view, _html} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    view
  end

  defp add_fun(fun), do: EndpointStubs.put(build_queue_add_fun: fun)

  test "queue-add uses CLI default queue, replies pending, and pushes success" do
    owner = self()

    add_fun(fn ids, queue ->
      send(owner, {:add, ids, queue})
      :ok
    end)

    view = open_view()
    render_hook(view, "queue-add", %{id: "42"})
    assert_reply(view, %{"v" => 1, "kind" => "queue-add", "id" => "42", "state" => "pending"})
    LiveViewAsync.render_when_complete(view)
    assert_received {:add, ["42"], "default"}
    assert_push_event(view, "build-queue-add", %{"v" => 1, "kind" => "queue-add-result", "id" => "42", "ok" => true})
    assert :sys.get_state(view.pid).socket.assigns.queue_add_pending == MapSet.new()
  end

  test "read-only mount and runtime revocation both refuse without adding" do
    owner = self()
    add_fun(fn _, _ -> send(owner, :unexpected_add) end)
    view = open_view(false)
    Phoenix.Config.put(Endpoint, :dashboard_writable, true)
    render_hook(view, "queue-add", %{id: "42"})
    assert_reply(view, %{"kind" => "error", "reason" => "read_only"})
    writable_view = open_view()
    Phoenix.Config.put(Endpoint, :dashboard_writable, false)
    render_hook(writable_view, "queue-add", %{id: "42"})
    assert_reply(writable_view, %{"kind" => "error", "reason" => "read_only"})
    refute_received :unexpected_add
  end

  test "invalid ids and parameter shapes never start a queue mutation" do
    owner = self()
    add_fun(fn _, _ -> send(owner, :unexpected_add) end)
    view = open_view()

    for params <- [%{}, %{id: 42}, %{id: %{}}, %{id: "0"}, %{id: "042"}, %{id: "-42"}, %{id: "12345678901"}, %{id: "42\n"}] do
      render_hook(view, "queue-add", params)
      assert_reply(view, %{"kind" => "error", "reason" => "invalid_params"})
    end

    refute_received :unexpected_add
    assert :sys.get_state(view.pid).socket.assigns.queue_add_pending == MapSet.new()
  end

  test "duplicate click is single-flight and a completed request can be retried" do
    owner = self()

    add_fun(fn [id], _queue ->
      send(owner, {:adding, id, self()})
      receive do: (:release -> {:error, :closed})
    end)

    view = open_view()
    render_hook(view, "queue-add", %{id: "42"})
    assert_reply(view, %{"state" => "pending"})
    receive_barrier({:adding, "42", task})
    render_hook(view, "queue-add", %{id: "42"})
    assert_reply(view, %{"state" => "pending"})
    refute_received {:adding, _, _}
    send(task, :release)
    LiveViewAsync.render_when_complete(view)
    assert_push_event(view, "build-queue-add", %{"ok" => false, "reason" => "closed"})
    render_hook(view, "queue-add", %{id: "42"})
    assert_reply(view, %{"state" => "pending"})
    receive_barrier({:adding, "42", retry_task})
    send(retry_task, :release)
    LiveViewAsync.render_when_complete(view)
  end

  test "queue responses preserve duplicate ownership, refusals and persisted uncertainty" do
    cases = [
      {{:ok, {:not_observed, ["42"]}}, %{"ok" => true}},
      {{:error, {:already_queued, "another"}}, %{"ok" => true, "reason" => "already_queued", "queue" => "another"}},
      {{:error, :closed}, %{"ok" => false, "reason" => "closed"}},
      {{:error, :store_unavailable}, %{"ok" => false, "reason" => "store_unavailable"}},
      {{:error, :unsupported_tracker}, %{"ok" => false, "reason" => "unsupported_tracker"}},
      {{:error, :inputs_unavailable}, %{"ok" => false, "reason" => "refused"}},
      {{:error, :outcome_unknown}, %{"ok" => false, "reason" => "outcome_unknown"}},
      {{:error, {:marker_write_failed, [{:mark, "42", {:error, :timeout}}]}}, %{"ok" => false, "reason" => "outcome_unknown"}}
    ]

    view = open_view()

    for {result, expected} <- cases do
      add_fun(fn _, _ -> result end)
      render_hook(view, "queue-add", %{id: "42"})
      assert_reply(view, %{"state" => "pending"})
      LiveViewAsync.render_when_complete(view)
      assert_push_event(view, "build-queue-add", pushed)
      assert Map.take(pushed, Map.keys(expected)) == expected
      assert pushed["id"] == "42"
      assert :sys.get_state(view.pid).socket.assigns.queue_add_pending == MapSet.new()
    end
  end

  test "task exit reports outcome unknown and keeps the LiveView alive" do
    add_fun(fn _, _ -> exit(:queue_crash) end)
    view = open_view()
    render_hook(view, "queue-add", %{id: "42"})
    assert_reply(view, %{"state" => "pending"})
    LiveViewAsync.render_when_complete(view)
    assert_push_event(view, "build-queue-add", %{"id" => "42", "ok" => false, "reason" => "outcome_unknown"})
    assert Process.alive?(view.pid)
    assert :sys.get_state(view.pid).socket.assigns.queue_add_pending == MapSet.new()
  end
end
