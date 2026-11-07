Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ExecutorLiveTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Store, TestSupport}
  alias Aiur.Executor.{CapabilityProvider, Session}
  alias AiurWeb.Endpoint

  setup context do
    context = TestSupport.setup(context)
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))
    start_supervised!({Session, instance_key: "executor-view"})
    monitor = Process.whereis(Aiur.Capabilities.Monitor)
    if monitor, do: :sys.suspend(monitor)
    previous_report = :ets.lookup(:aiur_capabilities, :report)
    :ets.insert(:aiur_capabilities, {:report, {%{capabilities: %{}}, System.monotonic_time(:millisecond), nil}})

    on_exit(fn ->
      :ets.delete(:aiur_capabilities, :report)
      :ets.insert(:aiur_capabilities, previous_report)
      if monitor && Process.alive?(monitor), do: :sys.resume(monitor)

      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end
    end)

    context
  end

  defp footer(path \\ "/") do
    {:ok, page, _html} = live(build_conn(), path)
    footer = find_live_child(page, "executor-footer-live")
    {page, footer, render(footer)}
  end

  test "footer on every dashboard page: label, state and a collapsed circle expand button" do
    for path <- ["/", "/commands", "/analytics", "/streamdeck"] do
      {_page, view, _html} = footer(path)
      assert has_element?(view, "#executor-footer .executor-footer__label", "Executor")
      assert has_element?(view, "#executor-footer-state", "not attached")
      assert has_element?(view, "#executor-footer-toggle[aria-expanded=false][aria-controls=executor-footer-panel]")
      assert has_element?(view, "#executor-footer-panel[hidden]")
    end
  end

  test "worker conversation pages carry no footer" do
    {:ok, page, _html} = live(build_conn(), "/conversations/" <> Aiur.Conversation.Ref.conversation_id(Aiur.Conversation.Ref.executor()))
    refute has_element?(page, "#executor-footer")
  end

  test "no binding is not opted in, never idle, with the attach command" do
    {_page, view, html} = footer()
    assert has_element?(view, "#executor-footer[data-state=not_opted_in]")
    assert html =~ "aiur executor-attach --harness claude"
    assert html =~ "--harness codex"
    assert has_element?(view, "#executor-frame a[href='https://aiur.team/docs/guide/gui#executor']")
    refute render(element(view, "#executor-footer-state")) =~ "idle"
    refute html =~ "age unknown"
  end

  test "awaiting first hook updates to detached on refresh" do
    assert {:ok, binding} = Session.attach(%{harness: "claude"})
    {_page, view, html} = footer()
    assert has_element?(view, "[data-state=awaiting_hook]")
    assert html =~ "Waiting for the Executor session"
    assert html =~ "aiur executor-attach --check"
    assert {:ok, _} = Session.detach(binding.binding_id, :detached)
    send(view.pid, :age_tick)
    assert has_element?(view, "#executor-footer[data-state=ended]")
    assert has_element?(view, "#executor-footer-state", "ended")
  end

  test "detached and removed bindings preserve history", %{ref: ref} do
    assert {:ok, binding} = Session.attach(%{harness: "claude"})
    Ingest.append(ref, source(), [event(1), event(2)])
    assert :ok = flush(ref)
    assert {:ok, _} = Session.detach(binding.binding_id, :detached)
    {_page, view, html} = footer()
    assert html =~ "message 1"
    assert has_element?(view, "#executor-footer[data-state=ended]")
    stop_supervised!(Session)
    send(view.pid, :age_tick)
    assert has_element?(view, "[data-state=ended]")
    assert has_element?(view, "#entry-2", "message 2")
  end

  test "read-only keeps live tail without a composer", %{ref: ref} do
    Phoenix.Config.put(Endpoint, :dashboard_writable, false)
    assert {:ok, binding} = Session.attach(%{harness: "claude"})
    assert {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: "session-one"})
    {_page, view, html} = footer()
    assert html =~ "Read-only Executor view"
    refute has_element?(view, "#conversation-composer")
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    assert has_element?(view, "#entry-1", "message 1")
    assert has_element?(view, "#executor-footer[data-state=live]")
    assert has_element?(view, "#executor-footer-state", "attached")
  end

  test "unreadable transcript and unsupported capture retain history", %{ref: ref} do
    Ingest.append(ref, source(), [event(1)])
    Ingest.gap(ref, :source_unreadable, DateTime.utc_now(), DateTime.utc_now())
    assert :ok = flush(ref)
    :ets.insert(:aiur_capabilities, {:report, {%{capabilities: %{"executor.conversation" => %{state: :unsupported, reason: :fixture_unsupported}}}, System.monotonic_time(:millisecond), nil}})
    {_page, view, html} = footer()
    assert has_element?(view, "#entry-1", "message 1")
    assert html =~ "Executor transcript unreadable (source_unreadable)"
    assert html =~ "Executor transcript unsupported: fixture_unsupported"
  end

  test "corrupt journal is unavailable rather than not attached", %{ref: ref, dir: dir} do
    Ingest.append(ref, source(), [event(1)])
    assert :ok = flush(ref)
    File.write!(Store.segment_path(dir, 1), "broken\n")
    {_page, view, _} = footer()
    assert has_element?(view, "#executor-footer[data-state=unavailable]")
    refute has_element?(view, "[data-state=not_opted_in]")
  end

  test "/executor redirects to the expanded footer and old positions to full history" do
    assert redirected_to(get(build_conn(), "/executor")) == "/?executor=open"
    id = Aiur.Conversation.Ref.conversation_id(Aiur.Conversation.Ref.executor())
    assert redirected_to(get(build_conn(), "/executor?pos=3")) == "/conversations/#{URI.encode(id, &URI.char_unreserved?/1)}?pos=3"
  end

  test "navigation no longer lists Executor; the capability route still resolves" do
    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "#ax-nav a", "Executor")
    refute has_element?(view, "a[href='/executor']")
    assert CapabilityProvider.evaluate(%{})["executor.conversation"].route == "/executor"
  end
end
