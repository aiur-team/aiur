defmodule Aiur.Project.Pause do
  @moduledoc """
  Pauses one project of a gateway: sets that project's own flag (persisted in its state
  root) and leaves every other project dispatching. The whole-gateway switch is
  `Aiur.Gateway.Pause`.
  """
  import Aiur.ControlCLI.Protocol

  alias Aiur.ControlCLI.Reasons
  alias Aiur.Gateway
  alias Aiur.Orchestrator.GlobalPause
  alias Aiur.Project

  @spec set(Project.id(), boolean(), String.t()) :: {:ok, map()} | {:error, term()}
  def set(project_id, on?, source) when is_binary(project_id) and is_boolean(on?) do
    id = String.downcase(project_id)

    cond do
      Project.Supervisors.which_projects() == [] -> {:error, :no_projects_configured}
      is_nil(Project.Registry.root_pid(id)) -> {:error, {:unknown_project, id}}
      true -> GlobalPause.set_global_pause(Project.name(Aiur.Orchestrator, id), on?, source)
    end
  end

  @spec cli_pause(String.t()) :: :ok
  def cli_pause(project_id), do: cli(project_id, true)

  @spec cli_resume(String.t()) :: :ok
  def cli_resume(project_id), do: cli(project_id, false)

  defp cli(project_id, on?) do
    verb = if on?, do: "pause", else: "resume"
    id = String.downcase(project_id)

    guarded(verb, fn ->
      case set(id, on?, "CLI `#{verb} --project`") do
        {:ok, _status} ->
          IO.puts(message(id, on?))
          exit_marker(0)

        {:error, reason} ->
          control_error("aiur: failed to #{verb} project #{id} (#{Reasons.format_reason(reason)})")
          exit_marker(control_query_exit_code(reason))
      end
    end)
  end

  defp message(id, true), do: "aiur: project #{id} pause ON — no agents will be provisioned in #{id}"

  defp message(id, false) do
    if Gateway.Pause.paused?(),
      do: "aiur: project #{id} pause OFF — gateway pause is still ON, #{id} stays held",
      else: "aiur: project #{id} pause OFF — new starts resume in #{id}"
  end
end
