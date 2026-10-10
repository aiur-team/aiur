defmodule Aiur.TestSupport.ControlRoutingFixture do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.State

  def base_state(attrs) do
    struct!(
      State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          completed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          agent_totals: nil,
          codex_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 0
          }
        ],
        attrs
      )
    )
  end

  def running_entry(issue_id, attrs \\ []) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue_id,
      issue: %Issue{
        id: issue_id,
        identifier: issue_id,
        state: "in-progress",
        title: "Characterize control routing",
        tracker_identity: tracker_identity(issue_id)
      },
      control: %{
        status: :working,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        application_confirmation: :confirmed,
        generation: 101,
        version: 0
      },
      session_id: "thread-#{issue_id}",
      started_at: DateTime.utc_now()
    }
    |> Map.merge(Map.new(attrs))
  end

  def live_worker_workspace(issue_id) do
    workspace = Aiur.TestSupport.tmp_root!("aiur_control_routing_#{issue_id}")

    marker = Path.join(workspace, "must-survive")
    File.mkdir_p!(workspace)
    File.write!(marker, "present")
    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      File.rm_rf(workspace)
    end)

    {worker, workspace, marker}
  end

  def supervised_worker do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  def cancel_retry_timer(%{timer_ref: timer_ref, retry_token: retry_token}) do
    Process.cancel_timer(timer_ref)

    receive do
      {:retry_issue, _issue_id, ^retry_token} -> :ok
    after
      0 -> :ok
    end
  end

  def unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  def tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDO#{identifier}",
      identifier: "101",
      reason: nil
    }
  end
end
