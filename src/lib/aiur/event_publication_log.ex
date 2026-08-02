defmodule Aiur.EventPublicationLog do
  @moduledoc """
  Persists locally-known event publication outcomes independently of agent transcripts.

  Remote workers own their transcript files, but publication happens in the local
  Aiur runtime. Keeping these small coordination facts in the daemon-owned run log
  avoids duplicate transcript ownership and prevents an agent-controlled workspace
  from redirecting the append through a symlink.
  """

  alias Aiur.Config.Paths
  alias Aiur.DecisionLog
  alias Aiur.JSONSafe

  @filename "event-publications.ndjson"

  @doc "Canonical daemon-owned publication outcome stream for this run."
  @spec publication_file() :: Path.t()
  def publication_file do
    Application.get_env(
      :aiur,
      :event_publication_log_file,
      Path.join(Paths.log_root_dir(), @filename)
    )
  end

  @doc """
  Appends one publication outcome to the daemon-owned durable stream.

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
