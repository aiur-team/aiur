defmodule Aiur.PathSafety do
  @moduledoc false

  @max_symlink_depth 40
  @roots_key {__MODULE__, :roots}

  # Fixed roots may be reused within one synchronous batch, never across
  # polls. Candidate paths are deliberately excluded: a worker can replace
  # one with a symlink while the daemon is running.
  @spec with_cached_roots((-> result)) :: result when result: var
  def with_cached_roots(fun) do
    if Process.get(@roots_key) do
      fun.()
    else
      Process.put(@roots_key, %{})

      try do
        fun.()
      after
        Process.delete(@roots_key)
      end
    end
  end

  @spec canonical_root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonical_root(path) do
    path = Path.expand(path)

    case Process.get(@roots_key) do
      nil -> canonicalize(path)
      roots -> cached_root(path, roots)
    end
  end

  defp cached_root(path, roots) do
    case Map.fetch(roots, path) do
      {:ok, canonical} ->
        {:ok, canonical}

      :error ->
        # Failed or not-yet-created roots must be retried rather than retained.
        with {:ok, canonical} = result <- canonicalize(path) do
          remember_root(path, canonical, roots)
          result
        end
    end
  end

  defp remember_root(path, canonical, roots) do
    if match?({:ok, %File.Stat{type: :directory}}, raw_stat(canonical, :follow)),
      do: Process.put(@roots_key, Map.put(roots, path, canonical))
  end

  # Elixir's File.stat/lstat option contracts exclude :raw. Use the Erlang
  # API that declares it, retaining File.Stat for the path policy below.
  defp raw_stat(path, :follow), do: path |> :file.read_file_info([:raw]) |> file_stat()
  defp raw_stat(path, :nofollow), do: path |> :file.read_link_info([:raw]) |> file_stat()
  defp file_stat({:ok, record}), do: {:ok, File.Stat.from_record(record)}
  defp file_stat({:error, _reason} = error), do: error

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, %{}, 0) do
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

    case raw_stat(candidate_path, :nofollow) do
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
      Map.has_key?(visited, candidate_path) ->
        {:error, :symlink_cycle}

      depth >= @max_symlink_depth ->
        {:error, :too_many_symlinks}

      true ->
        resolve_symlink_target(candidate_path, root, resolved_segments, rest, visited, depth)
    end
  end

  defp resolve_symlink_target(candidate_path, root, resolved_segments, rest, visited, depth) do
    with {:ok, target} <- :prim_file.read_link_all(String.to_charlist(candidate_path)) do
      resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
      {target_root, target_segments} = split_absolute_path(resolved_target)

      resolve_segments(
        target_root,
        [],
        target_segments ++ rest,
        Map.put(visited, candidate_path, true),
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
    with {:ok, canonical_root} <- canonical_root(root),
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
