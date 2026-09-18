defmodule Aiur.EventPublicationLog do
  @moduledoc """
  Persists locally-known event publication outcomes independently of agent transcripts.

  Remote workers own their transcript files, but publication happens in the local
  Aiur runtime. Keeping these small coordination facts in the daemon-owned run log
  avoids duplicate transcript ownership and prevents an agent-controlled workspace
  from redirecting the append through a symlink.

  ## Per-launch on purpose

  The stream lives in the per-launch log directory and is intentionally split
  per launch (#2722). "Durable" here means each append is fsynced before it is
  acknowledged, not that one file spans restarts. The daemon only appends; no
  running code reads the stream back, so a restart loses nothing it depends
  on. The only reader is the offline calibration collector
  (`docs/build-order/scripts/capture_progress_estimates.py`), which globs
  every launch's `<logs-root>/*/log/event-publications.ndjson` and so already
  sees the whole history.
  """

  alias Aiur.Config.Paths
  alias Aiur.DecisionLog
  alias Aiur.JSONSafe

  @filename "event-publications.ndjson"

  @doc "Canonical daemon-owned publication outcome stream for this launch."
  @spec publication_file() :: Path.t()
  def publication_file do
    Application.get_env(
      :aiur,
      :event_publication_log_file,
      Path.join(Paths.log_root_dir(), @filename)
    )
  end

  @doc """
  Appends one publication outcome to the daemon-owned, fsynced stream.

  The workspace argument is retained for caller compatibility but is never used
  to resolve the destination path.
  """
  @spec write(Path.t() | nil, map()) :: :ok | {:error, term()}
  def write(workspace, record), do: write(workspace, record, [])

  @doc false
  @spec write(Path.t() | nil, map(), keyword()) :: :ok | {:error, term()}
  def write(_workspace, record, opts) when is_map(record) and is_list(opts) do
    path = Keyword.get(opts, :path, publication_file())

    with :ok <- DecisionLog.prepare(Path.dirname(path), path) do
      DecisionLog.append(path, JSONSafe.normalize(record))
    end
  rescue
    error -> {:error, {:publication_log_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:publication_log_failure, kind, reason}}
  end

  def write(_workspace, _record, _opts), do: {:error, :invalid_publication_record}
end
