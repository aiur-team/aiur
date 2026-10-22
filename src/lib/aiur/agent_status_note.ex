defmodule Aiur.AgentStatusNote do
  @moduledoc """
  The agent status note: a short, machine-readable "doing / why / next /
  waiting on / asks / risks / pr" note the coding agent keeps current with
  `emit_event(name: "progress.status", ...)`.

  It exists so a reader (the Executor, the phone home view, the voice
  assistant's status card) can answer "what are you doing and why" from a
  note the agent already wrote, without stopping the agent to ask.

  The note is validated and redacted by `Aiur.AgentTools.StatusNote` before
  it is published. `record/4` then keeps the latest note per ticket in a
  small owner-only JSON file under the daemon-private state root (the
  decision state directory, not the agent-writable workspace or the
  per-launch log directory), so the note and its monotonic `version`
  survive a daemon restart. `latest/2` reads it.

  Writes for one ticket are serialized with `:global.trans/2`, so two
  concurrent `record/4` calls cannot read the same version or clobber each
  other; the file is replaced atomically with `Aiur.Fs.atomic_write/3` and a
  symlink or non-regular file at the note path is refused.
  """

  alias Aiur.Config.Paths, as: ConfigPaths
  alias Aiur.Fs
  alias Aiur.IssueLog.Paths, as: IssueLogPaths

  @state_leaf "agent-status-notes"

  @type note :: %{required(String.t()) => term()}

  @doc """
  Store `note` as the latest note for the ticket `identifier`, bumping the
  version. Returns the stored note with `version` and `observed_at`.

  Options: `:root` (directory; defaults to `<decision-state>/#{@state_leaf}`)
  and `:now` (`DateTime`, for tests).
  """
  @spec record(String.t(), String.t(), note(), keyword()) :: {:ok, note()} | {:error, term()}
  def record(identifier, message, note, opts \\ []) when is_binary(identifier) and is_binary(message) and is_map(note) do
    with {:ok, path} <- note_path(identifier, opts) do
      :global.trans({{__MODULE__, path}, self()}, fn -> write_next(path, message, note, opts) end)
    end
  end

  defp write_next(path, message, note, opts) do
    version =
      case latest_at(path) do
        {:ok, %{"version" => previous}} when is_integer(previous) -> previous + 1
        _none -> 1
      end

    observed_at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()
    stored = note |> Map.put("message", message) |> Map.put("version", version) |> Map.put("observed_at", observed_at)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- regular_or_missing(path),
         :ok <- Fs.atomic_write(path, Jason.encode!(stored), fsync: true, mode: 0o600) do
      {:ok, stored}
    end
  end

  defp regular_or_missing(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_rejected}
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The latest stored note for the ticket `identifier`, or `:none` when the
  agent has not written one (or the stored file is unreadable).
  """
  @spec latest(String.t(), keyword()) :: {:ok, note()} | :none
  def latest(identifier, opts \\ []) when is_binary(identifier) do
    case note_path(identifier, opts) do
      {:ok, path} -> latest_at(path)
      {:error, _reason} -> :none
    end
  end

  defp latest_at(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{} = note} <- Jason.decode(body) do
      {:ok, note}
    else
      _missing_or_corrupt -> :none
    end
  end

  defp note_path(identifier, opts) do
    with {:ok, root} <- state_root(opts) do
      {:ok, Path.join(root, "#{IssueLogPaths.configured_repository_scope()}.#{ConfigPaths.sanitize(identifier)}.json")}
    end
  end

  defp state_root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} -> {:ok, root}
      :error -> with {:ok, root} <- ConfigPaths.decision_state_dir(), do: {:ok, Path.join(root, @state_leaf)}
    end
  end
end
