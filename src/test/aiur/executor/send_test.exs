defmodule Aiur.Executor.SendTest do
  use ExUnit.Case, async: false
  alias Aiur.Conversation.Ref
  alias Aiur.Executor.Send
  alias Aiur.Listener

  defmodule Target do
    def executor_delivery_installed?, do: true

    def enqueue(target, text, opts) do
      send(self(), {:enqueued, target, text, opts})
      {:ok, 87}
    end
  end

  setup do
    previous = Application.fetch_env!(:aiur, :listener_delivery_target)
    Application.put_env(:aiur, :listener_delivery_target, Target)
    on_exit(fn -> Application.put_env(:aiur, :listener_delivery_target, previous) end)
    :ok
  end

  test "binding, delivery installation and write permission gate the adapter" do
    assert Send.capability(binding_fun: fn -> :none end) == {:unavailable, :not_attached}

    for binding <- [{:ok, %{live?: false}}, {:ok, %{live?: true, state: "awaiting_first_hook"}}] do
      assert Send.capability(binding_fun: fn -> binding end) == {:unavailable, :executor_unreachable}
    end

    assert Send.capability(opts(delivery_fun: fn -> false end)) == {:unavailable, :executor_delivery_not_installed}
    assert Send.capability(opts(writable: false)) == {:unavailable, :read_only}
    assert Send.capability(opts()) == :available
    assert Send.capability(binding_fun: fn -> exit(:noproc) end) == {:unavailable, :executor_unreachable}
  end

  test "send reaches the listener with Executor Ref and the original request id" do
    ref = Ref.executor()
    assert Send.send("hello", "request-one", opts()) == {:ok, 87}
    assert_receive {:enqueued, ^ref, "hello", options}, 1_000
    assert options == [delivery_policy: :listener, origin: :agent_chat, client_request_id: "request-one"]
    assert Send.send("forbidden", "request-two", opts(writable: false)) == {:error, :read_only}
    refute_received {:enqueued, _, "forbidden", _}
  end

  test "targets without an Executor feature check fail closed" do
    Application.put_env(:aiur, :listener_delivery_target, __MODULE__)
    refute Listener.executor_delivery_installed?()
    assert Send.capability(opts()) == {:unavailable, :executor_delivery_not_installed}
    assert Listener.send(Ref.executor(), "hello", []) == {:error, :invalid_message}
  end

  # Future regression guard: these paths must never type into the external terminal.
  test "future regression guard: Executor modules and conversation view never call terminal injection" do
    files = Path.wildcard("lib/aiur/executor/**/*.ex") ++ ["lib/aiur_web/live/conversation_live.ex", "lib/aiur_web/conversation/composer_events.ex"]

    for file <- files do
      text = File.read!(file)
      refute text =~ "Aiur.Tmux", file
      refute text =~ "OperatorInject", file
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge([binding_fun: fn -> {:ok, %{live?: true, state: "attached", provider_session_id: "session"}} end, writable: true], extra)
  end
end
