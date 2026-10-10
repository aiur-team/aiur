defmodule Aiur.Accounts.SessionMove do
  @moduledoc false

  # Moves a paused session's shim-declared artifacts between account profiles,
  # rolling back every rename or copy when a later step fails.

  alias Aiur.Accounts.SessionHistory

  @doc false
  @spec run((-> module()), Path.t(), Path.t(), String.t(), Path.t(), keyword()) :: :ok | {:error, term()} | term()
  def run(shim_fun, source_dir, destination_dir, session_id, cwd, opts) do
    with :ok <- inactive_session(source_dir, session_id, opts),
         shim <- shim_fun.(),
         :ok <- no_destination_artifacts(shim.session_artifacts(destination_dir, session_id, cwd)),
         artifacts <- shim.session_artifacts(source_dir, session_id, cwd),
         :ok <- require_session_artifact(artifacts),
         {:ok, movable_artifacts} <- destination_artifact_preflight(artifacts, source_dir, destination_dir),
         :ok <-
           move_artifacts(
             movable_artifacts,
             source_dir,
             destination_dir,
             session_id,
             Keyword.get(opts, :same_device, same_device?(source_dir, destination_dir)),
             opts
           ) do
      :ok
    end
  end

  defp inactive_session(dir, session_id, opts) do
    registry = Keyword.get(opts, :sessions_registry, Path.join(dir, "sessions"))

    live? = Path.wildcard(Path.join(registry, "*.json")) |> Enum.any?(&registry_entry_matches?(&1, session_id))

    if live?, do: {:error, :session_live}, else: :ok
  end

  defp registry_entry_matches?(path, session_id) do
    Path.basename(path, ".json") == session_id or registry_file_matches?(path, session_id)
  end

  defp registry_file_matches?(path, session_id) do
    with {:ok, contents} <- File.read(path),
         {:ok, data} <- Jason.decode(contents) do
      data["sessionId"] == session_id or data["session_id"] == session_id
    else
      _ -> false
    end
  end

  defp destination_artifact_preflight(artifacts, source_root, destination_root) do
    Enum.reduce_while(artifacts, {:ok, []}, fn source, {:ok, movable} ->
      destination = Path.join(destination_root, Path.relative_to(source, source_root))

      cond do
        not File.exists?(destination) and not match?({:ok, _}, File.lstat(destination)) ->
          {:cont, {:ok, [source | movable]}}

        same_file?(source, destination) ->
          {:cont, {:ok, movable}}

        true ->
          {:halt, {:error, :destination_session_exists}}
      end
    end)
    |> case do
      {:ok, movable} -> {:ok, Enum.reverse(movable)}
      error -> error
    end
  end

  defp no_destination_artifacts([]), do: :ok
  defp no_destination_artifacts(_artifacts), do: {:error, :destination_session_exists}

  defp require_session_artifact([]), do: {:error, :session_artifacts_missing}
  defp require_session_artifact(_artifacts), do: :ok

  defp move_artifacts(artifacts, source_root, destination_root, session_id, same_fs?, opts) do
    operations = Enum.map(artifacts, &{&1, Path.join(destination_root, Path.relative_to(&1, source_root))})

    case transfer_artifacts(operations, same_fs?, opts) do
      :ok ->
        finish_artifact_move(operations, source_root, destination_root, session_id, same_fs?, opts)

      error ->
        error
    end
  end

  defp transfer_artifacts(operations, true, opts),
    do: rename_artifacts(operations, [], Keyword.get(opts, :rename, &File.rename/2))

  defp transfer_artifacts(operations, false, opts),
    do: copy_artifacts(operations, [], Keyword.get(opts, :copy, &File.cp_r/2))

  defp finish_artifact_move(operations, source_root, destination_root, session_id, same_fs?, opts) do
    case SessionHistory.merge_history(source_root, destination_root, session_id, opts) do
      :ok -> remove_copied_sources(operations, same_fs?, opts)
      {:error, reason} -> rollback_transfer(operations, same_fs?, reason)
    end
  end

  defp remove_copied_sources(_operations, true, _opts), do: :ok

  defp remove_copied_sources(operations, false, opts) do
    case remove_sources(operations, Keyword.get(opts, :rm_rf, &File.rm_rf/1)) do
      :ok -> :ok
      {:error, reason, []} -> rollback_copies(operations, {:source_delete_failed, reason})
      {:error, reason, _deleted} -> {:error, {:source_delete_incomplete, reason}}
    end
  end

  defp rollback_transfer(operations, true, reason),
    do: rollback_renames(Enum.reverse(operations), reason)

  defp rollback_transfer(operations, false, reason), do: rollback_copies(operations, reason)

  defp rename_artifacts([], _moved, _rename), do: :ok

  defp rename_artifacts([{source, destination} | rest], moved, rename) do
    with :ok <- File.mkdir_p(Path.dirname(destination)),
         false <- File.exists?(destination) or match?({:ok, _}, File.lstat(destination)),
         :ok <- rename.(source, destination) do
      rename_artifacts(rest, [{source, destination} | moved], rename)
    else
      true -> rollback_renames(moved, :destination_session_exists)
      {:error, reason} -> rollback_renames(moved, reason)
    end
  end

  defp rollback_renames(moved, reason) do
    rollback =
      Enum.reduce(moved, :ok, fn {source, destination}, :ok ->
        with :ok <- File.mkdir_p(Path.dirname(source)), do: File.rename(destination, source)
      end)

    if rollback == :ok, do: {:error, reason}, else: {:error, {:rollback_failed, reason, rollback}}
  end

  defp copy_artifacts([], _copied, _copy), do: :ok

  defp copy_artifacts([{source, destination} | rest], copied, copy) do
    if File.exists?(destination) or match?({:ok, _}, File.lstat(destination)) do
      rollback_copies(copied, :destination_session_exists)
    else
      copy_artifact(source, destination, rest, copied, copy)
    end
  end

  defp copy_artifact(source, destination, rest, copied, copy) do
    with :ok <- File.mkdir_p(Path.dirname(destination)),
         {:ok, _} <- copy.(source, destination),
         true <- same_tree?(source, destination) do
      copy_artifacts(rest, [{source, destination} | copied], copy)
    else
      false ->
        File.rm_rf(destination)
        rollback_copies(copied, :copy_verification_failed)

      {:error, reason} ->
        File.rm_rf(destination)
        rollback_copies(copied, reason)
    end
  end

  defp rollback_copies(copied, reason) do
    rollback =
      Enum.reduce(copied, :ok, fn {_source, destination}, :ok ->
        case File.rm_rf(destination) do
          {:ok, _removed} -> :ok
          {:error, failure, _path} -> {:error, failure}
        end
      end)

    if rollback == :ok, do: {:error, reason}, else: {:error, {:rollback_failed, reason, rollback}}
  end

  defp remove_sources(operations, rm_rf) do
    Enum.reduce_while(operations, {:ok, []}, fn {source, _destination}, {:ok, deleted} ->
      case rm_rf.(source) do
        {:ok, _removed} -> {:cont, {:ok, [source | deleted]}}
        {:error, reason, _path} -> {:halt, {:error, reason, deleted}}
        {:error, reason} -> {:halt, {:error, reason, deleted}}
        {:error, reason, _path, _partial} -> {:halt, {:error, reason, deleted}}
      end
    end)
    |> case do
      {:ok, _deleted} -> :ok
      error -> error
    end
  end

  defp same_tree?(source, destination) do
    case {File.lstat(source), File.lstat(destination)} do
      {{:ok, %{type: :regular}}, {:ok, %{type: :regular}}} ->
        File.read!(source) == File.read!(destination)

      {{:ok, %{type: :directory}}, {:ok, %{type: :directory}}} ->
        left = Path.wildcard(Path.join(source, "**/*"), match_dot: true) |> Enum.map(&Path.relative_to(&1, source)) |> Enum.sort()
        right = Path.wildcard(Path.join(destination, "**/*"), match_dot: true) |> Enum.map(&Path.relative_to(&1, destination)) |> Enum.sort()
        left == right and Enum.all?(left, &same_tree?(Path.join(source, &1), Path.join(destination, &1)))

      _ ->
        false
    end
  end

  defp same_device?(left, right), do: File.stat!(left).major_device == File.stat!(right).major_device

  defp same_file?(left, right) do
    case {File.stat(left), File.stat(right)} do
      {{:ok, a}, {:ok, b}} -> a.major_device == b.major_device and a.inode == b.inode
      _ -> false
    end
  end
end
