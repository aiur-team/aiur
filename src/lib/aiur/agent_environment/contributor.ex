defmodule Aiur.AgentEnvironment.Contributor do
  @moduledoc "Registered additions to agent environments; the sandbox owns final credential scrubbing."

  @callback port_env(Path.t(), keyword()) :: [{charlist(), charlist() | false}]
  @callback shell_exports(Path.t(), keyword()) :: String.t()
  @callback repo_slug() :: String.t() | nil
  @callback agent_process_log_path() :: Path.t() | nil
  @callback hosted_credential_boundary() :: :daemon | :agent | :unknown
  @optional_callbacks repo_slug: 0, agent_process_log_path: 0, hosted_credential_boundary: 0

  @doc "List every registered contributor and its declared hosted credential boundary."
  @spec hosted_credential_boundaries() :: [{module(), :daemon | :agent | :unknown}]
  def hosted_credential_boundaries do
    Enum.map(contributors(), fn contributor ->
      boundary =
        if Code.ensure_loaded?(contributor) and function_exported?(contributor, :hosted_credential_boundary, 0),
          do: contributor.hosted_credential_boundary(),
          else: :unknown

      {contributor, boundary}
    end)
  end

  @spec port_env(Path.t(), keyword()) :: [{charlist(), charlist() | false}]
  def port_env(workspace, opts), do: Enum.flat_map(contributors(), & &1.port_env(workspace, opts))

  @spec shell_exports(Path.t(), keyword()) :: String.t()
  def shell_exports(workspace, opts), do: Enum.map_join(contributors(), & &1.shell_exports(workspace, opts))

  @spec repo_slug() :: String.t() | nil
  def repo_slug, do: first_value(:repo_slug)

  @spec agent_process_log_path() :: Path.t() | nil
  def agent_process_log_path, do: first_value(:agent_process_log_path)

  defp first_value(callback) do
    Enum.find_value(contributors(), fn contributor ->
      if Code.ensure_loaded?(contributor) and function_exported?(contributor, callback, 0),
        do: apply(contributor, callback, [])
    end)
  end

  defp contributors, do: Application.get_env(:aiur, :agent_environment_contributors, [])
end
