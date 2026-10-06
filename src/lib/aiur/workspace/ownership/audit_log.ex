defmodule Aiur.Workspace.Ownership.AuditLog do
  @moduledoc "Durable audit records for operator workspace recovery."

  alias Aiur.Config.Paths
  alias Aiur.DecisionLog
  alias Aiur.JSONSafe

  @filename "workspace-recovery-audit.ndjson"

  @spec write(map(), keyword()) :: :ok | {:error, term()}
  def write(record, opts \\ [])

  def write(record, opts) when is_map(record) and is_list(opts) do
    with {:ok, root} <- Paths.decision_state_dir(),
         dir = Path.join(root, "workspace-ownership"),
         path = Keyword.get(opts, :path, Application.get_env(:aiur, :workspace_ownership_audit_path, Path.join(dir, @filename))),
         :ok <- DecisionLog.prepare(Path.dirname(path), path),
         :ok <- DecisionLog.append(path, JSONSafe.normalize(record)) do
      :ok
    end
  rescue
    error -> {:error, {:audit_write_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:audit_write_failed, {kind, reason}}}
  end

  def write(_record, _opts), do: {:error, :invalid_audit_record}
end
