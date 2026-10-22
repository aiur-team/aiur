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
  small JSON file under the daemon-owned log root (not the agent-writable
  workspace), with a monotonic `version` and an `observed_at` timestamp.
  `latest/2` reads it.
  """

  alias Aiur.Config.Paths, as: ConfigPaths
  alias Aiur.IssueLog.Paths, as: IssueLogPaths

  @type note :: %{required(String.t()) => term()}

  @doc """
  Store `note` as the latest note for the ticket `identifier`, bumping the
  version. Returns the stored note with `version` and `observed_at`.

  Options: `:root` (directory; defaults to `<log-root>/status-notes`) and
  `:now` (`DateTime`, for tests).
  """
  @spec record(String.t(), String.t(), note(), keyword()) :: {:ok, note()} | {:error, term()}
  def record(identifier, message, note, opts \\ []) when is_binary(identifier) and is_binary(message) and is_map(note) do
    path = note_path(identifier, opts)

    version =
      case latest_at(path) do
        {:ok, %{"version" => previous}} when is_integer(previous) -> previous + 1
        _none -> 1
      end

    observed_at = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()
    stored = note |> Map.put("message", message) |> Map.put("version", version) |> Map.put("observed_at", observed_at)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(stored)),
         :ok <- File.rename(tmp, path) do
      {:ok, stored}
    end
  end

  @doc """
  The latest stored note for the ticket `identifier`, or `:none` when the
  agent has not written one (or the stored file is unreadable).
  """
  @spec latest(String.t(), keyword()) :: {:ok, note()} | :none
  def latest(identifier, opts \\ []) when is_binary(identifier) do
    identifier |> note_path(opts) |> latest_at()
  end

  defp latest_at(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = note} <- Jason.decode(body) do
      {:ok, note}
    else
      _missing_or_corrupt -> :none
    end
  end

  defp note_path(identifier, opts) do
    root = Keyword.get_lazy(opts, :root, fn -> Path.join(ConfigPaths.log_root_dir(), "status-notes") end)
    Path.join(root, "#{IssueLogPaths.configured_repository_scope()}.#{ConfigPaths.sanitize(identifier)}.json")
  end
end
