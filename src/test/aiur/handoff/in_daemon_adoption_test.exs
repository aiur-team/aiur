defmodule Aiur.Handoff.InDaemonAdoptionTest do
  @moduledoc """
  A fleet of OpenAI-compatible agents survives a keep-agents restart.

  Their conversation lives in this daemon's own session processes, so the handoff
  serializes it and the successor daemon re-adopts each ticket from the record
  instead of re-dispatching it.
  """

  use ExUnit.Case, async: false
  use Aiur.TestSupport.OpenAICompatAgent

  alias Aiur.AgentRunner.Handoff, as: RunnerHandoff
  alias Aiur.AgentRunner.Handoff.InDaemon
  alias Aiur.AppServer.ToolCallLedger
  alias Aiur.Handoff
  alias Aiur.Handoff.{Adopter, Record, Report}
  alias Aiur.OpenAICompat.{CodingAgent, Session}
  alias Aiur.OpenAICompat.Handoff, as: SessionHandoff

  @secret "in-daemon-secret-key"

  defmodule Owner do
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    def init(state), do: {:ok, state}
    def handle_call(:prepare_handoff_snapshot, _from, state), do: Handoff.hold_dispatch(state)
    def handle_call(:cancel_handoff, _from, state), do: Handoff.release_dispatch(state)
    def handle_call(:held?, _from, state), do: {:reply, Handoff.dispatch_held?(), state}
    def handle_info({:handoff_expired, _id, _token}, state), do: {:noreply, state}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "in-daemon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, ledger} = start_supervised({ToolCallLedger, name: nil})
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    on_exit(fn -> Aiur.Handoff.reset() end)
    %{dir: dir, ledger: ledger}
  end

  test "a fleet of OpenAI-compatible agents is adopted without re-dispatch", %{
    workspace: workspace,
    dir: dir,
    ledger: ledger
  } do
    parent = self()
    tickets = [{"1", "ISSUE-1"}, {"2", "ISSUE-2"}]
    runners = Enum.map(tickets, fn {id, _identifier} -> start_runner(parent, workspace, id) end)

    running =
      Map.new(Enum.zip(tickets, runners), fn {{id, identifier}, %{pid: pid, session: session}} ->
        {id,
         %{
           pid: pid,
           issue: %Aiur.Issue{id: id, identifier: identifier, title: "handoff", state: "in-progress"},
           session_execution: %{backend: "openrouter"},
           workspace_path: workspace,
           session_id: session.thread_id,
           started_at: DateTime.utc_now()
         }}
      end)

    {:ok, owner} = start_supervised({Owner, %{running: running, retry_attempts: %{}, dispatch_recovery: %{}}})

    assert {:ok, result} =
             Handoff.prepare(
               orchestrator: owner,
               ledger: ledger,
               dir: dir,
               config_fingerprint: "config"
             )

    assert result.skipped == []
    assert length(result.agents) == 2
    assert Enum.all?(result.agents, &is_nil(&1["fallback_reason"]))
    assert Enum.all?(result.agents, &(&1["transport"]["kind"] == "in_daemon"))

    saved =
      Map.new(result.agents, fn agent ->
        assert {:ok, provider_state} = SessionHandoff.provider_state(agent)
        assert provider_state["interrupted"] == false
        {agent["issue_id"], provider_state}
      end)

    assert {:ok, record} = Record.read(dir: dir)
    refute Jason.encode!(record) =~ @secret

    # The old daemon stops: its in-daemon sessions die with it. The record is
    # the only thing that crosses the gap.
    for %{pid: pid, session: session} <- runners do
      Process.exit(pid, :kill)
      CodingAgent.stop_session(session)
    end

    adopted = Adopter.adopt(%Aiur.Orchestrator.State{}, adoption_opts(dir, parent, workspace))

    assert adopted.running |> Map.keys() |> Enum.sort() == ["1", "2"]
    assert adopted.claimed == MapSet.new(["1", "2"])
    for {_id, entry} <- adopted.running, do: assert(is_binary(entry.adopted_from))

    for {id, _identifier} <- tickets do
      assert_receive {:continued, pid, ^id, restored}, 5_000
      %{messages: messages} = Session.get(restored.session_pid)
      assert Enum.any?(messages, &(&1["role"] == "user" and &1["content"] == "Work on #{id}"))
      # The restored conversation is the pre-restart one, and the adopted runner
      # continued it with a new turn rather than starting over.
      saved_roles = Enum.map(saved[id]["messages"], & &1["role"])
      assert Enum.take(Enum.map(messages, & &1["role"]), length(saved_roles)) == saved_roles
      assert length(messages) > length(saved_roles)
      send(pid, :stop)
    end

    assert {:ok, %{adopted: report_adopted, fallback: []}} = Report.latest(dir: dir)
    assert length(report_adopted) == 2
  end

  test "a mid-turn snapshot reports interrupted and a damaged one does not" do
    interrupted = in_daemon_record(%{"interrupted" => true, "messages" => []})
    boundary = in_daemon_record(%{"interrupted" => false, "messages" => []})

    assert InDaemon.interrupted?(interrupted)
    refute InDaemon.interrupted?(boundary)
    refute InDaemon.interrupted?(%{"transport" => %{"kind" => "in_daemon", "provider_state" => "not-a-snapshot"}})
    refute InDaemon.interrupted?(%{})
  end

  defp in_daemon_record(provider_state) do
    %{
      "transport" => %{
        "kind" => "in_daemon",
        "provider_state" => RunnerHandoff.encode(provider_state)
      }
    }
  end

  defp adoption_opts(dir, parent, workspace) do
    request_funs = %{
      "1" => fn request ->
        send(parent, {:request, "1", request})
        final_response("1")
      end,
      "2" => fn request ->
        send(parent, {:request, "2", request})
        final_response("2")
      end
    }

    [
      dir: dir,
      generation: 2,
      config_fingerprint: "config",
      backend: "openrouter",
      instance: instance(%{}),
      api_key_fetcher: fn _env -> @secret end,
      emit_alert: fn _name, _options -> :ok end,
      workspace: workspace,
      runner: fn agent, generation, recipient, opts_runner ->
        opts = Keyword.put(opts_runner, :request_fun, Map.fetch!(request_funs, agent["issue_id"]))
        {:ok, session} = RunnerHandoff.attach(agent, generation, opts)
        {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Continue ticket #{agent["issue_id"]}", issue(), on_message: fn _ -> :ok end)
        send(recipient, {:handoff_adopted, self(), {:ok, session}})
        receive do: (:handoff_continue -> send(parent, {:continued, self(), agent["issue_id"], session}))
        receive do: (:stop -> :ok)
      end
    ]
  end

  defp final_response(id) do
    response(%{
      "id" => "req-continue-#{id}",
      "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Continued #{id}."}}]
    })
  end

  # Each runner owns a real OpenAI-compatible session with one completed turn,
  # then parks at the turn boundary exactly as a production runner does between
  # turns. The pre-queued hold is consumed by `before_turn/2` when it runs.
  defp start_runner(parent, workspace, id) do
    opts = session_opts(parent, id)
    {:ok, session} = CodingAgent.start_session(workspace, opts)
    session = Map.put(session, :backend, "openrouter")
    {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "Work on #{id}", issue(), on_message: fn _ -> :ok end)
    flush_requests()

    context = %{
      workspace: workspace,
      issue: %Aiur.Issue{id: id, identifier: id, title: "handoff", state: "in-progress"},
      opts: Keyword.put(opts, :workspace, workspace),
      turn_number: 1,
      max_turns: nil,
      worker_host: nil
    }

    pid =
      spawn(fn ->
        Process.put(:handoff_turn_context, context)
        receive do: (:go -> :ok)
        RunnerHandoff.before_turn(session, context)
        send(parent, {:parked, self()})
        receive do: (:stop -> :ok)
      end)

    send(pid, :handoff_hold)
    send(pid, :go)
    %{pid: pid, session: session}
  end

  defp session_opts(parent, id) do
    queue = start_response_queue(id)

    [
      backend: "openrouter",
      instance: instance(%{}),
      api_key_fetcher: fn _env -> @secret end,
      request_fun: queue_fun(queue, parent)
    ]
  end

  defp start_response_queue(id) do
    {:ok, queue} =
      Agent.start_link(fn ->
        [
          response(%{
            "id" => "req-#{id}",
            "choices" => [%{"finish_reason" => "stop", "message" => %{"role" => "assistant", "content" => "Working on #{id}."}}]
          })
        ]
      end)

    queue
  end

  defp flush_requests do
    receive do
      {:request, _request} -> flush_requests()
      {:request, _id, _request} -> flush_requests()
    after
      0 -> :ok
    end
  end
end
