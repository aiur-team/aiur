defmodule Aiur.Workspace.WipPreservation.Notices do
  @moduledoc """
  The worker restore notices of `Aiur.Workspace.WipPreservation`, and the
  refusal hold and operator discard files kept beside the saves.
  """

  require Logger

  alias Aiur.Signal
  alias Aiur.Workspace.WipPreservation.{Artifact, Capture}

  @hold_file "hold-alerted.json"
  @discard_file "discard-dirty-workspace"

  @type artifact :: Artifact.artifact()

  @doc """
  Returns the manifests of `workspace` whose notice no agent turn has carried
  yet, oldest first. Only saves of `ticket` (when given) in the current notice
  generation of the workspace count.
  """
  @spec pending_notices(Path.t(), String.t() | nil) :: [artifact()]
  def pending_notices(workspace, ticket \\ nil) when is_binary(workspace) do
    leaf = Path.basename(workspace)
    generation = Artifact.current_generation(leaf)

    leaf
    |> Artifact.artifact_dirs()
    |> Enum.flat_map(&Artifact.read_manifest(Path.join(&1, Capture.manifest_name())))
    |> Enum.filter(fn manifest ->
      is_nil(manifest["notice_delivered_at"]) and manifest["complete"] != false and
        Map.get(manifest, "notice_generation", 0) == generation and
        (is_nil(ticket) or Map.get(manifest, "ticket", ticket) == ticket)
    end)
  end

  @doc """
  Puts the restore notice of every pending save of `ticket` in front of
  `prompt`. Returns the prompt and the notices it carries; pass them to
  `mark_delivered/1` once the turn has run.
  """
  @spec with_pending_notices(Path.t(), String.t() | nil, String.t()) :: {String.t(), [artifact()]}
  def with_pending_notices(workspace, ticket, prompt) when is_binary(workspace) and is_binary(prompt) do
    case pending_notices(workspace, ticket) do
      [] -> {prompt, []}
      notices -> {notice_text(notices) <> "\n" <> prompt, notices}
    end
  end

  @doc "The agent-facing text for `notices`."
  @spec notice_text([artifact()]) :: String.t()
  def notice_text(notices) when is_list(notices) do
    body =
      Enum.map_join(notices, "\n", fn notice ->
        """
        - Saved at #{notice["created_at"]} before Aiur tried to #{notice["action"] || "delete the workspace"}: #{notice["artifact_dir"]}
          HEAD at save time #{notice["head"] || "(no commit)"} on branch #{notice["branch"] || "(detached)"}; #{length(notice["tracked_files"] || [])} tracked and #{length(notice["untracked_files"] || [])} untracked files.#{skipped_line(notice)}
          Restore with these commands, in order. They apply the work to the current HEAD:
        #{Enum.map_join(notice["restore_commands"] || [], "\n", &("      " <> &1))}
        """
      end)

    """
    Aiur preserved uncommitted work (#2743):

    Aiur had to delete or recreate this workspace while it still held uncommitted changes. It saved the changes first; they are not in the current workspace. Restore them before you continue, or say in the workpad why they are no longer needed. This notice can repeat after a restart; if the work is already restored, do not restore it twice.
    #{body}
    """
  end

  defp skipped_line(%{"skipped_untracked" => [_ | _] = skipped}),
    do: " Not saved because of the size bounds: " <> Enum.map_join(skipped, ", ", & &1["path"]) <> "."

  defp skipped_line(_notice), do: ""

  @doc "Records that an agent turn carried `notices`."
  @spec mark_delivered([artifact()]) :: :ok
  def mark_delivered(notices) when is_list(notices) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each(notices, fn %{"manifest_path" => path} = notice ->
      manifest = notice |> Map.delete("manifest_path") |> Map.put("notice_delivered_at", now)

      case Artifact.write_json(path, manifest) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Could not mark preserved-work notice delivered path=#{path} reason=#{inspect(reason)}")
      end
    end)
  end

  @doc """
  Authorizes Aiur to delete the workspace with this leaf without a save, the
  next time it tries. Use it for a dirty remote checkout or a local one whose
  save keeps failing, after you decided the work is not needed.
  """
  @spec authorize_discard(String.t()) :: :ok | {:error, term()}
  def authorize_discard(leaf) when is_binary(leaf) do
    with {:ok, dir} <- Artifact.workspace_dir(leaf),
         :ok <- Artifact.mkdir_private(dir),
         do: Artifact.write_file(Path.join(dir, @discard_file), DateTime.utc_now() |> DateTime.to_iso8601())
  end

  @doc "True when the discard file authorizes the delete of this workspace leaf without a save."
  @spec discard_authorized?(String.t()) :: boolean()
  def discard_authorized?(leaf), do: File.exists?(discard_path(leaf))

  @doc "Records that the authorized discard happened, so it does not apply again."
  @spec consume_discard(String.t()) :: :ok
  def consume_discard(leaf) do
    _ = File.rm(discard_path(leaf))
    :ok
  end

  @doc "Forgets the refusal of this workspace leaf: it was deleted or discarded."
  @spec clear_hold(String.t()) :: :ok
  def clear_hold(leaf) do
    with {:ok, dir} <- Artifact.workspace_dir(leaf), do: File.rm(Path.join(dir, @hold_file))
    :ok
  end

  @doc "Alerts the discard of a workspace whose work was not saved."
  @spec emit_discarded_alert(String.t(), Path.t(), term()) :: :ok
  def emit_discarded_alert(ticket, workspace, reason) do
    message = "Deleted the workspace of #{ticket} at #{workspace} without saving its uncommitted work, as an operator authorized (#{inspect(reason)})."
    _ = Signal.alert("ticket.#{ticket}.workspace.wip_discarded", issue: ticket, message: message, reason: message, severity: "warning")
    :ok
  end

  @doc false
  @spec discard_path(String.t()) :: Path.t()
  def discard_path(leaf) do
    case Artifact.workspace_dir(leaf) do
      {:ok, dir} -> Path.join(dir, @discard_file)
      {:error, _reason} -> Path.join(["<runtime_state_dir>", Artifact.root_name(), leaf, @discard_file])
    end
  end

  @doc false
  @spec hold_alerted?(String.t(), String.t()) :: boolean()
  def hold_alerted?(leaf, key) do
    with {:ok, dir} <- Artifact.workspace_dir(leaf),
         {:ok, body} <- File.read(Path.join(dir, @hold_file)),
         {:ok, %{"key" => ^key}} <- Jason.decode(body) do
      true
    else
      _ -> false
    end
  end

  @doc false
  @spec record_hold(String.t(), String.t()) :: term()
  def record_hold(leaf, key) do
    with {:ok, dir} <- Artifact.workspace_dir(leaf),
         :ok <- Artifact.mkdir_private(dir),
         :ok <- Artifact.write_json(Path.join(dir, @hold_file), %{"key" => key, "at" => DateTime.utc_now() |> DateTime.to_iso8601()}) do
      :ok
    else
      {:error, reason} -> Logger.warning("Could not record the preserved-work refusal leaf=#{leaf} reason=#{inspect(reason)}")
    end
  end
end
