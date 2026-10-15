Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RetryEngine.ClaimsAndReapingTest do
  use Aiur.TestSupport

  alias Aiur.Claude.RemoteControl
  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  import Aiur.RetryEngineFixture, only: [seed_metadata: 0]

  describe "claim release scheduling (#2427)" do
    test "a transient transport failure releases the claim with a scheduled re-claim" do
      issue_id = "issue-claim-transient"

      initial = %State{
        claimed: MapSet.new([issue_id]),
        released_claims: %{},
        retry_attempts: %{}
      }

      final =
        Enum.reduce(1..3, {initial, seed_metadata()}, fn attempt, {state, metadata} ->
          next =
            RetryEngine.handle_retry_poll_failure(
              state,
              issue_id,
              attempt,
              metadata,
              # A raw `%Req.TransportError{}` DNS failure, exactly as the
              # transport error funnel (`transport.ex`) surfaces it to the
              # tracker poll. `:nxdomain` is deliberately the reason: it is
              # transient to the shared classifier but was never in the
              # provider-timeout whitelist, so without the AutoResume
              # normalisation this test fails (no re-claim scheduled).
              %Req.TransportError{reason: :nxdomain}
            )

          case next.retry_attempts[issue_id] do
            %{timer_ref: timer_ref} = retry when timer_ref != nil ->
              Process.cancel_timer(timer_ref)
              {next, retry}

            _released ->
              {next, metadata}
          end
        end)
        |> elem(0)

      # The claim is released at poll exhaustion, but never *without* a
      # scheduled re-claim: a DNS failure is transient, so an automatic
      # re-claim is queued instead of demanding operator recovery. The cause is
      # pinned to the shared classifier's verdict (`:transient_tracker`), not
      # the provider-timeout whitelist (#2427 review finding 4).
      refute MapSet.member?(final.claimed, issue_id)
      assert Map.has_key?(final.released_claims, issue_id)
      assert %{cause: :transient_tracker} = final.auto_resume[issue_id]
    end
  end

  describe "orphaned shell reaping" do
    test "reaps a tracked headless shell tree when its runner exits" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.ORPHAN-1.agent.orphan_reaped")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      bash = System.find_executable("bash") || flunk("bash executable unavailable")
      port = Port.open({:spawn_executable, String.to_charlist(bash)}, [:binary, args: [~c"-c", ~c"sleep 600 & wait"]])
      assert {:os_pid, shell_pid} = :erlang.port_info(port, :os_pid)
      child_pid = wait_for_child_process(shell_pid)

      on_exit(fn ->
        RemoteControl.graceful_kill_tree(shell_pid)

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
      end)

      issue_id = "issue-orphan-#{System.unique_integer([:positive])}"
      ref = make_ref()

      state = %State{
        running: %{
          issue_id => %{
            ref: ref,
            identifier: "ORPHAN-1",
            started_at: DateTime.utc_now(),
            retry_attempt: 0,
            headless_os_pid: shell_pid,
            headless_process_group_id: nil
          }
        },
        claimed: MapSet.new([issue_id])
      }

      assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, :killed)
      assert after_down.orphaned_agent_reap_count == 1
      refute RemoteControl.process_alive?(shell_pid)
      refute RemoteControl.process_alive?(child_pid)
      assert_receive {:event, %{topic: "ticket.ORPHAN-1.agent.orphan_reaped"} = event}, 500
      assert event["needs_attention"] == true
      assert event["message"] =~ "orphaned_agent_reap_count=1"
    end
  end

  defp wait_for_child_process(parent_pid, attempts \\ 20)

  defp wait_for_child_process(_parent_pid, 0), do: flunk("headless shell did not spawn its child")

  defp wait_for_child_process(parent_pid, attempts) do
    case System.find_executable("pgrep") do
      nil ->
        flunk("pgrep executable unavailable")

      pgrep ->
        case System.cmd(pgrep, ["-P", Integer.to_string(parent_pid)], stderr_to_stdout: true) do
          {output, 0} ->
            output |> String.trim() |> String.to_integer()

          _ ->
            Process.sleep(25)
            wait_for_child_process(parent_pid, attempts - 1)
        end
    end
  end
end
