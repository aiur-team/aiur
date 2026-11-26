defmodule Aiur.ControlCall.Audit do
  @moduledoc "Appends privacy-preserving remote control outcomes to the daemon log."

  alias Aiur.Config.Paths
  alias Aiur.Journal
  alias Aiur.JSONSafe

  @filename "control-audit.ndjson"

  @spec audit_file() :: Path.t()
  def audit_file do
    Application.get_env(:aiur, :control_audit_file, Path.join(Paths.log_root_dir(), @filename))
  end

  @spec append(map()) :: :ok | {:error, term()}
  def append(record) when is_map(record) do
    path = audit_file()

    with :ok <- Journal.prepare(Path.dirname(path), path) do
      Journal.append(path, JSONSafe.normalize(record))
    end
  rescue
    error -> {:error, {:audit_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:audit_failure, kind, reason}}
  end
end
