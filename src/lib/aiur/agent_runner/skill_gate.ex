defmodule Aiur.AgentRunner.SkillGate do
  @moduledoc """
  Holds a dispatch whose mandatory skills cannot reach the worker.

  Mapped skills are the role instructions a worker must follow. This gate runs
  after the workspace is prepared and before any session starts. A mapped
  skill with no `SKILL.md`, or a mapped set over `agent.skills.preload_max_bytes`,
  raises an alert naming the ticket, the skills and their mapping reasons.
  Under `agent.skills.strict` the dispatch is blocked (held on the preflight
  pause, so a resume re-checks); otherwise it proceeds with every installed
  mapped skill inlined.
  """

  alias Aiur.AgentSkills.Preload
  alias Aiur.Alerts

  @doc """
  `:ok` to start the session, or `{:blocked, message}` under strict mode.

  Options: `:skill_preload` (an already-resolved preload), `:alert_fun`
  (defaults to `Aiur.Alerts.emit_system/2`) and `:worker_host`.
  """
  @spec check(Aiur.Issue.t(), Path.t(), keyword()) :: :ok | {:blocked, String.t()}
  # ponytail: skill files are read from the local filesystem, so a remote (SSH)
  # workspace is not gated; gate it once Preload can read a worker host.
  def check(issue, workspace, opts \\ []) do
    if is_nil(Keyword.get(opts, :worker_host)), do: gate(issue, workspace, opts), else: :ok
  end

  defp gate(issue, workspace, opts) do
    preload = Keyword.get_lazy(opts, :skill_preload, fn -> Preload.resolve(issue, workspace) end)

    case problems(preload) do
      [] ->
        :ok

      problems ->
        alert = Keyword.get(opts, :alert_fun, &Alerts.emit_system/2)
        detail = Enum.join(problems, "; ")

        if preload.strict? do
          message = "Mandatory skills block dispatch of ##{issue.identifier}: #{detail}. Install the skills or fix agent.skills, then resume."
          alert.("ticket.#{issue.identifier}.skills.blocked", message: message, issue: issue, workspace: workspace, needs_attention: true, severity: "error")
          {:blocked, message}
        else
          message = "Mandatory skills for ##{issue.identifier}: #{detail}. Dispatching anyway (agent.skills.strict is off)."
          alert.("ticket.#{issue.identifier}.skills.warning", message: message, issue: issue, workspace: workspace, severity: "warning")
          :ok
        end
    end
  end

  defp problems(%Preload{} = preload) do
    missing =
      case preload.missing do
        [] -> []
        skills -> ["not installed: " <> Enum.map_join(skills, ", ", &"#{&1.name} (#{&1.reason})")]
      end

    over_budget =
      if Preload.over_budget?(preload) do
        sizes = Enum.map_join(preload.mapped, ", ", &"#{&1.name} #{&1.bytes}")
        ["over agent.skills.preload_max_bytes: #{preload.bytes}/#{preload.max_bytes} bytes (#{sizes})"]
      else
        []
      end

    missing ++ over_budget
  end
end
