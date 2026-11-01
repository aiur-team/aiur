Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ExecutorLiveComposerTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{Ingest, Ref, TestSupport}
  alias Aiur.Executor.Session
  alias AiurWeb.Endpoint

  defmodule Target do
    def executor_delivery_installed?, do: Endpoint.config(:executor_delivery_test).installed
    def get_mode(%Ref{subject: :executor}), do: Endpoint.config(:executor_test_mode, {:ok, %{effective: :steer}})

    def enqueue(target, text, opts) do
      config = Endpoint.config(:executor_delivery_test)
      send(config.owner, {:executor_send, target, text, opts})
      config.result
    end

    def read_snapshot(_, _), do: {:error, :unavailable}
  end

  setup context do
    context = TestSupport.setup(context)
    previous = Map.new([:executor_state_dir, :listener_delivery_target], &{&1, Application.fetch_env(:aiur, &1)})
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))
    Application.put_env(:aiur, :listener_delivery_target, Target)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:aiur, key, value)
          :error -> Application.delete_env(:aiur, key)
        end
      end
    end)

    start_supervised!({Session, instance_key: "executor-composer"})
    configure(dashboard_writable: true, executor_delivery_test: %{owner: self(), installed: true, result: {:ok, 73}})
    context
  end

  test "not attached renders a disabled composer with a reason and rejects a forged send" do
    {:ok, view, html} = open()
    assert html =~ "Executor not attached"
    assert has_element?(view, "#conversation-text[disabled]")
    render_click(view, "send", %{"text" => "forged"})
    refute_received {:executor_send, _, _, _}
    assert has_element?(view, "[data-delivery-state=failed]", "not_attached")
  end

  test "missing delivery support disables composer even with a live binding" do
    attach()
    configure(executor_delivery_test: %{owner: self(), installed: false, result: {:ok, 73}})
    {:ok, view, html} = open()
    assert html =~ "Executor delivery not installed"
    assert has_element?(view, "#conversation-composer button[disabled]")
    render_click(view, "send", %{"text" => "forged"})
    refute_received {:executor_send, _, _, _}
    assert has_element?(view, "[data-delivery-state=failed]", "executor_delivery_not_installed")
  end

  test "Executor sends share overlay, receipt polling and durable reconciliation" do
    binding = attach()
    ref = Ref.executor()
    {:ok, view, html} = open()
    assert html =~ "Steer · interrupts"
    refute has_element?(view, ".conversation-mode select")
    view |> form("#conversation-composer", %{"text" => "inspect run"}) |> render_submit()
    assert_receive {:executor_send, ^ref, "inspect run", opts}, 1_000
    assert opts[:origin] == :agent_chat
    assert is_binary(opts[:client_request_id])
    assert has_element?(view, "[data-delivery-state=accepted]", "Waiting until the Executor’s next turn")
    configure(conversation_receipt_fun: fn 73 -> {:ok, %{receipt: :harness_queued}} end)
    send(view.pid, :delivery_tick)
    assert has_element?(view, "[data-delivery-state=queued]", "Waiting until the Executor’s next turn")
    Ingest.append(ref, source(binding.provider_session_id), [%{role: "user", body: "inspect run", payload: %{delivery_id: "73"}, timestamp: DateTime.utc_now()}])
    assert :ok = flush(ref)
    assert has_element?(view, "#conversation-entries", "inspect run")
    refute has_element?(view, "[data-delivery-state=queued]")
  end

  test "unknown mode stays explicit while an available text path remains usable" do
    attach()
    configure(executor_test_mode: {:error, :unavailable})
    {:ok, view, html} = open()
    assert html =~ "mode unknown"
    assert has_element?(view, "#conversation-text:not([disabled])")
    refute has_element?(view, "[data-voice-root]")
    view |> form("#conversation-composer", %{"text" => "next turn"}) |> render_submit()
    assert_receive {:executor_send, _, "next turn", _}, 1_000
  end

  test "detach after mount preserves failed draft; unknown receipts never claim delivery" do
    binding = attach()
    {:ok, view, _} = open()
    assert {:ok, _} = Session.detach(binding.binding_id, :operator)
    view |> form("#conversation-composer", %{"text" => "keep draft"}) |> render_submit()
    assert has_element?(view, "[data-delivery-state=failed]", "executor_unreachable")
    assert has_element?(view, "textarea", "keep draft")
    refute_received {:executor_send, _, _, _}
    attach()
    {:ok, other, _} = open()
    other |> form("#conversation-composer", %{"text" => "uncertain"}) |> render_submit()
    send(other.pid, :delivery_tick)
    assert has_element?(other, "[data-delivery-state=unknown]", "Outcome unknown")
    refute has_element?(other, "[data-delivery-state=delivered]")
    configure(dashboard_writable: false)
    render_click(other, "send", %{"text" => "revoked"})
    refute_received {:executor_send, _, "revoked", _}
  end

  defp attach do
    {:ok, pending} = Session.attach(%{harness: "claude"})
    {:ok, binding} = Session.bind_provider_session(pending.binding_id, %{session_id: "executor-session"})
    binding
  end

  defp open, do: live(build_conn(), "/conversations/" <> Ref.conversation_id(Ref.executor()))

  defp configure(opts) do
    updated = Keyword.merge(Application.get_env(:aiur, Endpoint, []), opts)
    Application.put_env(:aiur, Endpoint, updated)
    Endpoint.config_change([{Endpoint, updated}], [])
  end
end
