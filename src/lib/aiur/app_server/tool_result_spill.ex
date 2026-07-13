defmodule Aiur.AppServer.ToolResultSpill do
  @moduledoc false

  require Logger
  alias Aiur.{PathSafety, Workspace.GitMetadata}

  @max_inline_frame_bytes 100 * 1024
  @runtime_dir ".aiur-runtime"
  @results_dir "tool-results"

  @spec maybe_spill(term(), map() | nil) :: term()
  def maybe_spill(%{"success" => true} = result, %{workspace: workspace, response_id: response_id})
      when is_binary(workspace) do
    if frame_size(result, response_id) > @max_inline_frame_bytes do
      spill(result, workspace)
    else
      result
    end
  end

  def maybe_spill(result, _context), do: result

  defp frame_size(result, response_id) do
    %{"jsonrpc" => "2.0", "id" => response_id, "result" => result}
    |> Jason.encode_to_iodata!()
    |> IO.iodata_length()
    |> Kernel.+(1)
  end

  defp spill(result, workspace) do
    payload = Jason.encode!(result, pretty: true)

    with {:ok, canonical_workspace, directory} <- prepare_directory(workspace),
         {:ok, path} <- atomic_write(canonical_workspace, directory, payload) do
      bounded_result(path)
    else
      {:error, reason} ->
        Logger.warning("oversized tool result spill failed reason=#{inspect(reason)}")
        bounded_failure()
    end
  end

  defp prepare_directory(workspace) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- File.dir?(canonical_workspace),
         :ok <- GitMetadata.ensure_tool_results_excluded(canonical_workspace),
         {:ok, runtime_dir} <- ensure_private_directory(canonical_workspace, @runtime_dir),
         {:ok, results_dir} <- ensure_private_directory(runtime_dir, @results_dir),
         {:ok, %{candidate: ^results_dir}} <- PathSafety.contained?(canonical_workspace, results_dir) do
      {:ok, canonical_workspace, results_dir}
    else
      false -> {:error, :workspace_not_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_private_directory(parent, name) do
    path = Path.join(parent, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.chmod(path, 0o700), do: {:ok, path}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlinked_spill_directory, path}}

      {:ok, _stat} ->
        {:error, {:invalid_spill_directory, path}}

      {:error, :enoent} ->
        with :ok <- File.mkdir(path),
             :ok <- File.chmod(path, 0o700),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
          {:ok, path}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp atomic_write(canonical_workspace, directory, contents) do
    token = 12 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    path = Path.join(directory, "tool-result-#{token}.json")
    tmp = Path.join(directory, ".tool-result-#{token}.tmp")

    try do
      with {:ok, io} <- :file.open(String.to_charlist(tmp), [:write, :binary, :raw, :exclusive]),
           :ok <- write_and_sync(io, tmp, contents),
           :ok <- verify_destination(canonical_workspace, directory, path),
           :ok <- File.rename(tmp, path) do
        {:ok, path}
      end
    after
      _ = File.rm(tmp)
    end
  end

  defp write_and_sync(io, tmp, contents) do
    with :ok <- File.chmod(tmp, 0o600),
         :ok <- :file.write(io, contents) do
      :file.sync(io)
    end
  after
    :ok = :file.close(io)
  end

  defp verify_destination(canonical_workspace, directory, path) do
    runtime_dir = Path.join(canonical_workspace, @runtime_dir)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(runtime_dir),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:error, :enoent} <- File.lstat(path),
         {:ok, %{root: ^canonical_workspace, candidate: ^path}} <- PathSafety.contained?(canonical_workspace, path) do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlinked_spill_directory}
      {:ok, _stat} -> {:error, :spill_target_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_result(path) do
    message = "Tool result exceeded #{@max_inline_frame_bytes} inline bytes and was saved as JSON to #{path}. Read the file from disk in chunks."
    %{"success" => true, "output" => message, "contentItems" => [%{"type" => "inputText", "text" => message}]}
  end

  defp bounded_failure do
    %{
      "success" => false,
      "output" => "Tool result exceeded the inline limit but could not be saved safely.",
      "contentItems" => []
    }
  end
end
