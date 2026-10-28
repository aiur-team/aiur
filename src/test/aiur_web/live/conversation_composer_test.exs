Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationComposerTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{History, Ingest, Ref, TestSupport}
  alias AiurWeb.Endpoint

  defmodule Target do
    def enqueue(target, text, opts) do
      config = Endpoint.config(:composer_test)
      send(config.owner, {:listener_send, target, text, opts})
      config.result
    end

    def get_mode(_), do: {:ok, %{effective: :sync, requested: :sync, effective_reason: nil}}
    def read_snapshot(_, _), do: {:error, :unavailable}
  end

  setup context do
    context = TestSupport.setup(context)
    previous = Application.fetch_env!(:aiur, :listener_delivery_target)
    Application.put_env(:aiur, :listener_delivery_target, Target)
    on_exit(fn -> Application.put_env(:aiur, :listener_delivery_target, previous) end)
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I_composer", "number" => 6635}, {"owner", "repo"}, {"owner", "repo"})
    {:ok, ref} = Ref.worker(identity)
    Ingest.append(ref, %{source() | role: :worker}, [event(1)])
    assert :ok = flush(ref)
    configure(dashboard_writable: true, composer_test: %{owner: self(), result: {:ok, 42}})
    Map.merge(context, %{ref: ref, identity: identity})
  end

  test "Listener receives verified identity, listener policy and origin; journal removes overlay", %{ref: ref, identity: identity} do
    {:ok, view, html} = open(ref)
    assert html =~ "Sync · next turn"
    send_text(view, "hello")
    assert_receive {:listener_send, ^identity, "hello", opts}, 1_000
    assert opts[:origin] == :agent_chat
    assert opts[:delivery_policy] == :listener
    assert is_binary(opts[:client_request_id])
    assert has_element?(view, "[data-delivery-state=accepted]", "hello")
    assert field(view) == ""
    Ingest.append(ref, %{source() | role: :worker}, [%{role: "user", body: "hello", payload: %{delivery_id: "42"}, timestamp: DateTime.utc_now()}])
    assert :ok = flush(ref)
    assert {:ok, page} = History.list_entries(ref, principal: :internal)
    assert Enum.any?(page.entries, &(&1.kind == "operator_message" && &1.refs.delivery_id == "42"))
    refute has_element?(view, "[data-delivery-state=accepted]")
    assert has_element?(view, "#conversation-entries", "hello")
  end

  test "read-only hides composer and rejects forged sends including revoked write access", %{ref: ref} do
    configure(dashboard_writable: false)
    {:ok, view, html} = open(ref)
    assert html =~ "Read-only dashboard"
    refute has_element?(view, "#conversation-composer")
    render_click(view, "send", %{"text" => "forged"})
    refute_received {:listener_send, _, "forged", _}
    configure(dashboard_writable: true)
    {:ok, writable, _} = open(ref)
    assert has_element?(writable, "#conversation-composer")
    configure(dashboard_writable: false)
    render_click(writable, "send", %{"text" => "revoked"})
    refute_received {:listener_send, _, "revoked", _}
  end

  test "unknown retry preserves draft and request id; edited text gets a new action", %{ref: ref} do
    configure(composer_test: %{owner: self(), result: {:error, {:outcome_unknown, %{item_id: 42}}}})
    {:ok, view, _} = open(ref)
    send_text(view, "retry me")
    assert_receive {:listener_send, _, "retry me", first}, 1_000
    assert field(view) == "retry me"
    assert has_element?(view, "[data-delivery-state=unknown]", "Outcome unknown")
    send_text(view, "retry me")
    assert_receive {:listener_send, _, "retry me", second}, 1_000
    assert first[:client_request_id] == second[:client_request_id]
    send_text(view, "changed")
    assert_receive {:listener_send, _, "changed", third}, 1_000
    assert third[:client_request_id] != first[:client_request_id]
  end

  test "unknown effective mode is explicit even when requested mode is known", %{ref: ref} do
    configure(conversation_mode_fun: fn _ -> {:ok, %{requested: :sync, effective: nil}} end)
    {:ok, view, html} = open(ref)
    assert html =~ "mode unknown"
    refute has_element?(view, "select")
    refute html =~ "Sync · next turn"
  end

  test "polling renders queued and async states and restores failed draft", %{ref: ref} do
    configure(conversation_receipt_fun: fn 42 -> {:ok, %{receipt: :harness_queued}} end)
    {:ok, view, _} = open(ref)
    send_text(view, "work")
    send(view.pid, :delivery_tick)
    assert has_element?(view, "[data-delivery-state=queued]", "Queued for next boundary")
    configure(conversation_receipt_fun: fn 42 -> {:ok, %{receipt: :held_async}} end)
    send(view.pid, :delivery_tick)
    assert has_element?(view, "[data-delivery-state=held_async]", "reads it when it chooses")
    configure(conversation_receipt_fun: fn 42 -> {:ok, %{receipt: :failed, failure_reason: :provider_rejected}} end)
    send(view.pid, :delivery_tick)
    assert has_element?(view, "[data-delivery-state=failed]", "provider_rejected")
    assert field(view) == "work"
    configure(conversation_receipt_fun: fn _ -> flunk("terminal item polled") end)
    send(view.pid, :delivery_tick)
    assert field(view) == "work"
  end

  test "accepted send schedules receipt polling without user interaction", %{ref: ref} do
    owner = self()

    configure(
      conversation_receipt_fun: fn id ->
        send(owner, {:receipt_polled, id})
        {:ok, %{receipt: :harness_queued}}
      end
    )

    {:ok, view, _} = open(ref)
    send_text(view, "scheduled")
    assert_receive {:receipt_polled, 42}, 4_000
    assert has_element?(view, "[data-delivery-state=queued]")
  end

  test "lost receipt becomes unknown without a delivered claim", %{ref: ref} do
    {:ok, view, _} = open(ref)
    send_text(view, "uncertain")
    send(view.pid, :delivery_tick)
    assert has_element?(view, "[data-delivery-state=unknown]", "check the agent")
    refute render(view) =~ "data-delivery-state=\"delivered\""
  end

  test "tampered subjects and Executor conversations cannot become worker targets", %{ref: ref, root: root} do
    assert {:ok, _} = History.worker_identity(Ref.conversation_id(ref))
    path = Path.join([root, Ref.conversation_id(ref), "subject.json"])
    data = path |> File.read!() |> Jason.decode!() |> Map.put("provider_id", "I_different")
    File.write!(path, Jason.encode!(data))
    assert {:error, :unavailable} = History.worker_identity(Ref.conversation_id(ref))
    {:ok, view, _} = open(ref)
    refute has_element?(view, "#conversation-composer")
    assert {:error, :unavailable} = History.worker_identity(Ref.conversation_id(Ref.executor()))
  end

  defp open(ref), do: live(build_conn(), "/conversations/" <> Ref.conversation_id(ref))
  defp send_text(view, text), do: view |> form("#conversation-composer", %{"text" => text}) |> render_submit()
  defp field(view), do: view |> render() |> Floki.parse_document!() |> Floki.find("#conversation-text") |> Floki.text()

  defp configure(opts) do
    updated = Keyword.merge(Application.get_env(:aiur, Endpoint, []), opts)
    Application.put_env(:aiur, Endpoint, updated)
    Endpoint.config_change([{Endpoint, updated}], [])
  end
end
