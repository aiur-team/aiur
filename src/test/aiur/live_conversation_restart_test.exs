defmodule Aiur.LiveConversationRestartTest do
  use ExUnit.Case, async: false

  alias Aiur.{LiveConversation, TrackerIdentity}

  test "the actual supervised projection restarts without replay or source I/O" do
    unique = Integer.to_string(System.unique_integer([:positive]))

    source = %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "owner",
        repository: "repo",
        provider_id: "restart-provider-#{unique}",
        identifier: unique,
        reason: nil
      },
      run_id: "restart-run-#{unique}",
      attempt_id: "restart-attempt-#{unique}",
      session_id: "restart-session-#{unique}",
      backend: "codex",
      worker_generation: 1
    }

    assert {:ok, %{generation_handle: handle, messages: [%{body: "before restart"}]}} =
             LiveConversation.observe(source, %{
               role: :assistant,
               msg_id: "restart-message",
               body: "before restart"
             })

    assert :ok = LiveConversation.subscribe(source)
    prior = Process.whereis(LiveConversation)
    ref = Process.monitor(prior)
    Process.exit(prior, :kill)
    assert_receive {:DOWN, ^ref, :process, ^prior, :killed}, 2_000

    replacement = await_replacement(prior, 200)
    assert is_pid(replacement)
    assert :sys.get_state(replacement).snapshots == %{}

    assert_receive {:live_conversation_restarted, "projection:" <> _, %DateTime{}}, 2_000

    assert %{state: :restart_unknown, health: :unknown, freshness: :unknown, messages: []} =
             LiveConversation.snapshot(source)

    assert {:ok,
            %{
              state: :restart_unknown,
              health: :unknown,
              freshness: :unknown,
              generation_handle: ^handle,
              messages: []
            }} = LiveConversation.resolve(handle)
  end

  defp await_replacement(_prior, 0), do: flunk("LiveConversation was not restarted")

  defp await_replacement(prior, attempts) do
    case Process.whereis(LiveConversation) do
      pid when is_pid(pid) and pid != prior ->
        pid

      _other ->
        Process.sleep(10)
        await_replacement(prior, attempts - 1)
    end
  end
end
