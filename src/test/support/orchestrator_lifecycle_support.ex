defmodule Aiur.OrchestratorLifecycleSupport do
  @moduledoc false

  import Aiur.TestSupport, only: [write_workflow_file!: 2]
  import ExUnit.Callbacks

  alias Aiur.Events.SubscriptionStore
  alias Aiur.{Issue, Orchestrator, Workflow}

  defmodule HermeticReworkGitHubClient do
    @moduledoc false
    def update_issue_state(issue_id, state_name) do
      if is_pid(recipient()), do: send(recipient(), {:hermetic_rework_update, issue_id, state_name})

      Agent.get_and_update(agent(), fn
        [result | rest] -> {result, rest}
        [] -> {:ok, []}
      end)
    end

    def update_issue_state(issue_id, state_name, _opts),
      do: update_issue_state(issue_id, state_name)

    def fetch_issue_states_by_ids(issue_ids) do
      wanted = MapSet.new(issue_ids)
      {:ok, Enum.filter(issues(), &(&1.id in wanted or &1.identifier in wanted))}
    end

    def fetch_candidate_issues, do: {:ok, issues()}

    def hydrate_blocked_by(issue), do: {:ok, issue}

    def fetch_classified_issue_comments(_issue_id), do: {:ok, []}

    # These hermetic scenarios model trusted rework feedback on a GitHub ticket
    # that is actively being reworked, so the open-PR precondition (#2075)
    # holds: rework is legitimate because an open PR exists. A `nil` here would
    # refuse the rework transition the tests are actually exercising.
    def fetch_open_pull_request_for_branch(_issue_id), do: {:ok, %{}}

    defp agent, do: Application.fetch_env!(:aiur, :hermetic_rework_agent)
    defp issues, do: Application.get_env(:aiur, :hermetic_rework_issues, [])
    defp recipient, do: Application.get_env(:aiur, :hermetic_rework_recipient)
  end

  defmodule ResumeRefreshGitHubClient do
    @moduledoc false
    def fetch_issue_states_by_ids(_issue_ids) do
      Agent.get_and_update(agent(), fn [result | rest] -> {result, rest} end)
    end

    def remove_label(issue_identifier, label) do
      send(recipient(), {:resume_refresh_remove_label, issue_identifier, label})
      :ok
    end

    defp agent, do: Application.fetch_env!(:aiur, :resume_refresh_agent)
    defp recipient, do: Application.fetch_env!(:aiur, :resume_refresh_recipient)
  end

  def running_entry(issue_id, identifier, status) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: nil},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: status},
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  def start_orchestrator(name) do
    unless Process.whereis(Aiur.Supervisor) do
      {:ok, _apps} = Application.ensure_all_started(:aiur)
    end

    {:ok, pid} = Orchestrator.start_link(name: name, initial_poll?: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  def worker_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  def base_state(attrs \\ []) do
    struct!(
      Orchestrator.State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          session_max_concurrent_agents: nil,
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
        ],
        attrs
      )
    )
  end

  def todo_issue(id), do: %Issue{id: id, identifier: id, state: "todo", title: "Todo"}

  def review_issue(id),
    do: %Issue{id: id, identifier: id, state: "human-review", title: "Review"}

  def memory_tracker!(issues) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    Application.put_env(:aiur, :memory_tracker_issues, issues)
  end

  def resume_refresh_tracker!(responses) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    {:ok, agent} = Agent.start_link(fn -> responses end)
    previous_client = Application.get_env(:aiur, :github_client_module)
    Application.put_env(:aiur, :github_client_module, ResumeRefreshGitHubClient)
    Application.put_env(:aiur, :resume_refresh_agent, agent)
    Application.put_env(:aiur, :resume_refresh_recipient, self())

    on_exit(fn ->
      restore_app_env(:github_client_module, previous_client)
      Application.delete_env(:aiur, :resume_refresh_agent)
      Application.delete_env(:aiur, :resume_refresh_recipient)
    end)
  end

  def restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  def restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  def isolated_subscription_store(identifier) do
    tmp_dir = Aiur.TestSupport.tmp_root!("aiur_reg_orc_life")
    original = Application.get_env(:aiur, :log_file)
    File.mkdir_p!(tmp_dir)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "aiur.log"))

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      if original, do: Application.put_env(:aiur, :log_file, original), else: Application.delete_env(:aiur, :log_file)
      Aiur.TestCleanup.rm_rf!(tmp_dir)
    end)
  end

  def comment_event(identifier, topic, trusted? \\ true, body \\ "please rework") do
    %{
      id: System.unique_integer([:positive]),
      topic: "ticket.#{identifier}.#{topic}",
      source: :github,
      author_trusted?: trusted?,
      message: body,
      comment: %{"body" => body}
    }
  end
end
