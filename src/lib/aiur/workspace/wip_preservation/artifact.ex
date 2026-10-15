defmodule Aiur.Workspace.WipPreservation.Artifact do
  @moduledoc """
  Writes the save directories of `Aiur.Workspace.WipPreservation`: the private
  per-workspace directory, its notice generation, the manifest and the alerts
  about a written save.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.Signal
  alias Aiur.Workspace.WipPreservation.{Capture, Retention}

  @root_name "wip-preserved"
  @generation_file "generation"

  @type artifact :: %{required(String.t()) => term()}

  @doc false
  @spec root_name() :: String.t()
  def root_name, do: @root_name

  @doc "The save directory root for one workspace leaf."
  @spec workspace_dir(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def workspace_dir(leaf) when is_binary(leaf) do
    with {:ok, root} <- root_dir(), do: {:ok, Path.join(root, Paths.sanitize(leaf, "issue"))}
  end

  defp root_dir do
    case Paths.runtime_state_dir() do
      {:ok, root} -> {:ok, Path.join(root, @root_name)}
      {:error, reason} -> {:error, {:runtime_state_dir_unavailable, reason}}
    end
  end

  @doc """
  Expires every pending notice of a workspace leaf: its ticket closed. Saves
  written after this call belong to the next generation.
  """
  @spec expire_notices(String.t()) :: :ok
  def expire_notices(leaf) when is_binary(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         true <- File.dir?(dir),
         :ok <- write_file(Path.join(dir, @generation_file), Integer.to_string(current_generation(leaf) + 1)) do
      :ok
    else
      false -> :ok
      {:error, reason} -> Logger.warning("Could not expire preserved-work notices leaf=#{leaf} reason=#{inspect(reason)}")
    end
  end

  @doc "The notice generation of a workspace leaf; 0 until its ticket first closes."
  @spec current_generation(String.t()) :: non_neg_integer()
  def current_generation(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         {:ok, body} <- File.read(Path.join(dir, @generation_file)),
         {generation, _rest} when generation >= 0 <- Integer.parse(String.trim(body)) do
      generation
    else
      _ -> 0
    end
  end

  @doc false
  @spec write_artifact(Path.t(), String.t(), String.t() | nil, map()) :: {:ok, artifact()} | {:error, term()}
  def write_artifact(workspace, action, ticket, limits) do
    leaf = Path.basename(workspace)
    stamp = stamp()

    with {:ok, dir} <- workspace_dir(leaf),
         final = Path.join(dir, stamp),
         partial = Path.join(dir, Retention.partial_prefix() <> stamp),
         :ok <- mkdir_private(partial),
         context = %{workspace: workspace, partial: partial, final: final, limits: limits},
         {:ok, captured} <- discard_on_error(Capture.capture(context), partial),
         manifest = Map.merge(base_manifest(workspace, leaf, ticket, action, final), captured),
         :ok <- discard_on_error(write_json(Path.join(partial, Capture.manifest_name()), manifest), partial),
         :ok <- discard_on_error(promote(partial, final), partial) do
      prune(limits)
      {:ok, Map.put(manifest, "manifest_path", Path.join(final, Capture.manifest_name()))}
    end
  end

  @doc false
  @spec write_incomplete(Path.t(), String.t(), String.t(), term()) :: {:ok, artifact()} | {:error, term()}
  def write_incomplete(workspace, ticket, action, reason) do
    leaf = Path.basename(workspace)
    stamp = stamp()

    with {:ok, dir} <- workspace_dir(leaf),
         final = Path.join(dir, stamp),
         partial = Path.join(dir, Retention.partial_prefix() <> stamp),
         :ok <- mkdir_private(partial),
         manifest =
           workspace
           |> base_manifest(leaf, ticket, action, final)
           |> Map.merge(%{"complete" => false, "failure" => inspect(reason), "files" => %{}, "restore_commands" => []}),
         :ok <- discard_on_error(write_json(Path.join(partial, Capture.manifest_name()), manifest), partial),
         :ok <- discard_on_error(promote(partial, final), partial) do
      {:ok, manifest}
    end
  end

  defp base_manifest(workspace, leaf, ticket, action, final) do
    %{
      "version" => 2,
      "ticket" => ticket,
      "notice_generation" => current_generation(leaf),
      "workspace" => workspace,
      "workspace_leaf" => leaf,
      "action" => action,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "artifact_dir" => final,
      "complete" => true,
      "skipped_untracked" => [],
      "notice_delivered_at" => nil
    }
  end

  # The save appears under its final name only once every file is written,
  # so a reader never sees a half-written save.
  defp promote(partial, final) do
    case File.rename(partial, final) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_rename_failed, final, reason}}
    end
  end

  defp discard_on_error({:error, _reason} = error, partial) do
    File.rm_rf(partial)
    error
  end

  defp discard_on_error(result, _partial), do: result

  defp prune(limits) do
    with {:ok, root} <- root_dir(), do: Retention.prune(root, limits, &current_generation/1)
  end

  @doc false
  @spec artifact_dirs(String.t()) :: [Path.t()]
  def artifact_dirs(leaf) do
    with {:ok, dir} <- workspace_dir(leaf),
         {:ok, entries} <- File.ls(dir) do
      entries |> Enum.filter(&Retention.artifact_name?/1) |> Enum.sort() |> Enum.map(&Path.join(dir, &1))
    else
      _ -> []
    end
  end

  defp stamp do
    now = DateTime.utc_now()
    {usec, _precision} = now.microsecond

    Calendar.strftime(now, "%Y%m%dT%H%M%S") <>
      "." <> String.pad_leading(Integer.to_string(usec), 6, "0") <> "Z-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  # Creates `path` and makes it and every directory up to `wip-preserved/`
  # private to the daemon user: untracked files can hold secrets.
  @doc false
  @spec mkdir_private(Path.t()) :: :ok | {:error, term()}
  def mkdir_private(path) do
    with {:ok, root} <- root_dir(),
         :ok <- mkdir(path) do
      path
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.scan(root, &Path.join(&2, &1))
      |> then(&[root | &1])
      |> Enum.reduce_while(:ok, &chmod_private/2)
    end
  end

  defp chmod_private(dir, :ok) do
    case File.chmod(dir, 0o700) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:artifact_dir_unwritable, dir, reason}}}
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:artifact_dir_unwritable, path, reason}}
    end
  end

  @doc false
  @spec write_json(Path.t(), map()) :: :ok | {:error, term()}
  def write_json(path, map), do: write_file(path, Jason.encode_to_iodata!(map, pretty: true))

  @doc false
  @spec write_file(Path.t(), iodata()) :: :ok | {:error, term()}
  def write_file(path, content) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, content, [:sync]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, {:artifact_write_failed, path, reason}}
    end
  end

  @doc false
  @spec read_manifest(Path.t()) :: [artifact()]
  def read_manifest(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = manifest} <- Jason.decode(body) do
      [Map.put(manifest, "manifest_path", path)]
    else
      _ -> []
    end
  end

  @doc false
  @spec emit_preserved_alert(String.t(), String.t(), artifact()) :: term()
  def emit_preserved_alert(ticket, action, artifact) do
    skipped = artifact["skipped_untracked"] || []

    message =
      "Saved the uncommitted work of #{ticket} before Aiur tried to #{action}: #{length(artifact["tracked_files"])} tracked and " <>
        "#{length(artifact["untracked_files"])} untracked files at #{artifact["artifact_dir"]}." <>
        if(skipped == [], do: "", else: " #{length(skipped)} untracked paths were over the size bounds and not saved; the manifest lists them.") <>
        " The next agent turn gets the restore commands."

    Signal.alert("ticket.#{ticket}.workspace.wip_preserved",
      issue: ticket,
      message: message,
      reason: message,
      severity: "warning"
    )
  end

  @doc false
  @spec emit_incomplete_alert(String.t(), Path.t(), term(), artifact()) :: term()
  def emit_incomplete_alert(ticket, workspace, reason, artifact) do
    message =
      "Deleted the workspace of closed ticket #{ticket} at #{workspace} after its uncommitted-work save timed out (#{inspect(reason)}). " <>
        "Only a manifest was saved, at #{artifact["artifact_dir"]}."

    Signal.alert("ticket.#{ticket}.workspace.wip_preservation_incomplete",
      issue: ticket,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning"
    )
  end
end
