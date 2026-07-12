defmodule Aiur.PathSafety do
  @moduledoc false

  @max_symlink_depth 40

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, MapSet.new(), 0) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, [], _visited, _depth),
    do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], visited, depth) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow_symlink(candidate_path, root, resolved_segments, rest, visited, depth)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, visited, depth)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow_symlink(candidate_path, root, resolved_segments, rest, visited, depth) do
    cond do
      MapSet.member?(visited, candidate_path) ->
        {:error, :symlink_cycle}

      depth >= @max_symlink_depth ->
        {:error, :too_many_symlinks}

      true ->
        resolve_symlink_target(candidate_path, root, resolved_segments, rest, visited, depth)
    end
  end

  defp resolve_symlink_target(candidate_path, root, resolved_segments, rest, visited, depth) do
    with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
      resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
      {target_root, target_segments} = split_absolute_path(resolved_target)

      resolve_segments(
        target_root,
        [],
        target_segments ++ rest,
        MapSet.put(visited, candidate_path),
        depth + 1
      )
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end

  @doc """
  Asserts `candidate` canonicalizes (symlink-resolved) to `root` itself or
  a subpath of it. Returns the canonicalized pair so callers can layer
  their own additional rules on top (e.g. treating exact equality to
  root as disallowed) rather than baking every caller's policy in here.
  """
  @spec contained?(Path.t(), Path.t()) ::
          {:ok, %{root: Path.t(), candidate: Path.t()}} | {:error, :outside_root} | {:error, :unreadable}
  def contained?(root, candidate) do
    with {:ok, canonical_root} <- canonicalize(Path.expand(root)),
         {:ok, canonical_candidate} <- canonicalize(Path.expand(candidate)) do
      canonical_root_prefix = canonical_root <> "/"

      if canonical_candidate == canonical_root or
           String.starts_with?(canonical_candidate <> "/", canonical_root_prefix) do
        {:ok, %{root: canonical_root, candidate: canonical_candidate}}
      else
        {:error, :outside_root}
      end
    else
      {:error, {:path_canonicalize_failed, _path, _reason}} -> {:error, :unreadable}
    end
  end
end
