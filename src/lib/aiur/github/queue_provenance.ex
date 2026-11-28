defmodule Aiur.GitHub.QueueProvenance do
  @moduledoc false

  alias Aiur.{Config.Paths, Journal}

  @filename "dispatch-queue-writes.ndjson"

  @doc "Records a successful local queue-label write in daemon-private state."
  @spec record(String.t(), String.t()) :: :ok | {:error, term()}
  def record(issue_id, label) when is_binary(issue_id) and is_binary(label) do
    with {:ok, dir} <- Paths.decision_state_dir(),
         path <- Application.get_env(:aiur, :dispatch_queue_provenance_file, Path.join(dir, @filename)),
         :ok <- Journal.prepare(Path.dirname(path), path),
         do: Journal.append(path, %{issue_id: issue_id, label: label, written_at: DateTime.utc_now() |> DateTime.to_iso8601()})
  rescue
    error -> {:error, {:provenance_exception, Exception.message(error)}}
  end

  @doc "Returns whether a timestamped local queue write matches the latest GitHub label event."
  @spec matches?(String.t(), String.t(), String.t() | nil, keyword()) :: boolean()
  def matches?(issue_id, label, created_at, opts \\ []) do
    path = Keyword.get(opts, :file, Keyword.get(opts, :dispatch_queue_provenance_file, provenance_file()))

    with timestamp when is_binary(timestamp) <- created_at,
         {:ok, event_time, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, contents} <- File.read(path) do
      contents
      |> String.split("\n", trim: true)
      |> Enum.any?(&record_matches?(&1, issue_id, label, event_time))
    else
      _ -> false
    end
  end

  defp record_matches?(line, issue_id, label, event_time) do
    with {:ok, %{"issue_id" => ^issue_id, "label" => ^label, "written_at" => timestamp}} <- Jason.decode(line),
         {:ok, write_time, _offset} <- DateTime.from_iso8601(timestamp),
         delta when delta in -5_000..0 <- DateTime.diff(event_time, write_time, :millisecond) do
      true
    else
      _ -> false
    end
  end

  defp provenance_file do
    case Paths.decision_state_dir() do
      {:ok, dir} -> Application.get_env(:aiur, :dispatch_queue_provenance_file, Path.join(dir, @filename))
      _error -> ""
    end
  end
end
