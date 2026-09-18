defmodule Aiur.Workspace.WipPreservation.Retention do
  @moduledoc """
  Bounds the disk use of `wip-preserved/` (#2743).

  After each save, `prune/2` applies these rules in order:

    1. Each workspace keeps its newest `keep_per_workspace/0` saves.
    2. A save older than `workspace.wip_retention_days` is removed.
    3. While the whole directory is larger than `workspace.wip_retention_bytes`,
       the oldest save of a closed ticket is removed first, then the oldest
       older save of an open ticket.

  No rule removes the newest save of an open ticket. A ticket is open for a
  save when the save carries the current notice generation of its workspace;
  closing the ticket advances the generation (see
  `Aiur.Workspace.WipPreservation.expire_notices/1`). A `.partial-` directory
  older than one hour is from a save that crashed, and is removed.
  """

  @keep_per_workspace 5
  @partial_prefix ".partial-"
  @stale_partial_seconds 3_600
  @stamp ~r/^(\d{8}T\d{6})/

  @doc "How many saves each workspace keeps."
  @spec keep_per_workspace() :: pos_integer()
  def keep_per_workspace, do: @keep_per_workspace

  @doc "The directory name prefix of a save that is still being written."
  @spec partial_prefix() :: String.t()
  def partial_prefix, do: @partial_prefix

  @doc "True when `name` is the directory name of a completed save."
  @spec artifact_name?(String.t()) :: boolean()
  def artifact_name?(name), do: Regex.match?(@stamp, name)

  @doc """
  Prunes `root` (the `wip-preserved` directory). `limits` carries
  `:retention_bytes` and `:retention_days`; `generation_fun` returns the
  current notice generation of a workspace leaf.
  """
  @spec prune(Path.t(), map(), (String.t() -> non_neg_integer())) :: :ok
  def prune(root, limits, generation_fun) do
    now = DateTime.utc_now()
    artifacts = scan(root, now)
    protected = protected(artifacts, generation_fun)

    kept =
      artifacts
      |> Enum.group_by(& &1.leaf)
      |> Enum.flat_map(fn {_leaf, saves} -> saves |> Enum.sort_by(& &1.name, :desc) |> drop_extra(protected) end)
      |> drop_expired(now, limits.retention_days, protected)

    drop_over_cap(kept, limits.retention_bytes, protected, generation_fun)
    :ok
  end

  defp scan(root, now) do
    root
    |> ls()
    |> Enum.map(&{&1, Path.join(root, &1)})
    |> Enum.filter(fn {_leaf, dir} -> File.dir?(dir) end)
    |> Enum.flat_map(fn {leaf, dir} -> scan_leaf(leaf, dir, now) end)
  end

  defp scan_leaf(leaf, dir, now) do
    dir
    |> ls()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)

      cond do
        String.starts_with?(name, @partial_prefix) ->
          remove_stale_partial(path, now)
          []

        artifact_name?(name) and File.dir?(path) ->
          [%{leaf: leaf, name: name, path: path, created_at: created_at(name), generation: generation(path), bytes: bytes(path)}]

        true ->
          []
      end
    end)
  end

  defp protected(artifacts, generation_fun) do
    artifacts
    |> Enum.group_by(& &1.leaf)
    |> Enum.flat_map(fn {leaf, saves} ->
      current = generation_fun.(leaf)

      saves
      |> Enum.filter(&(&1.generation == current))
      |> Enum.max_by(& &1.name, fn -> nil end)
      |> List.wrap()
    end)
    |> MapSet.new(& &1.path)
  end

  defp drop_extra(saves, protected) do
    {kept, extra} = Enum.split(saves, @keep_per_workspace)
    {extra_kept, extra_removed} = Enum.split_with(extra, &MapSet.member?(protected, &1.path))
    Enum.each(extra_removed, &File.rm_rf(&1.path))
    kept ++ extra_kept
  end

  defp drop_expired(saves, now, days, protected) do
    cutoff = now |> DateTime.add(-days * 86_400, :second) |> DateTime.to_naive()

    Enum.reject(saves, fn save ->
      expired? = NaiveDateTime.compare(save.created_at, cutoff) == :lt and not MapSet.member?(protected, save.path)
      if expired?, do: File.rm_rf(save.path)
      expired?
    end)
  end

  defp drop_over_cap(saves, cap, protected, generation_fun) do
    total = saves |> Enum.map(& &1.bytes) |> Enum.sum()

    saves
    |> Enum.reject(&MapSet.member?(protected, &1.path))
    |> Enum.sort_by(&{open?(&1, generation_fun), &1.name})
    |> Enum.reduce_while(total, fn save, remaining ->
      if remaining <= cap do
        {:halt, remaining}
      else
        File.rm_rf(save.path)
        {:cont, remaining - save.bytes}
      end
    end)
  end

  defp open?(save, generation_fun), do: save.generation == generation_fun.(save.leaf)

  defp remove_stale_partial(path, now) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        if DateTime.to_unix(now) - mtime > @stale_partial_seconds, do: File.rm_rf(path)

      {:error, _reason} ->
        :ok
    end
  end

  defp created_at(name) do
    [stamp] = Regex.run(@stamp, name, capture: :all_but_first)

    case parse_stamp(stamp) do
      {:ok, at} -> at
      :error -> ~N[1970-01-01 00:00:00]
    end
  end

  # "20260918T041406" -> ~N[2026-09-18 04:14:06]
  defp parse_stamp(<<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2>>) do
    case NaiveDateTime.from_iso8601("#{y}-#{m}-#{d}T#{h}:#{mi}:#{s}") do
      {:ok, at} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp generation(path) do
    with {:ok, body} <- File.read(Path.join(path, "manifest.json")),
         {:ok, %{} = manifest} <- Jason.decode(body),
         generation when is_integer(generation) <- Map.get(manifest, "notice_generation", 0) do
      generation
    else
      _ -> 0
    end
  end

  defp bytes(path) do
    path
    |> ls()
    |> Enum.map(fn name ->
      case File.lstat(Path.join(path, name)) do
        {:ok, %File.Stat{size: size}} -> size
        {:error, _reason} -> 0
      end
    end)
    |> Enum.sum()
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end
end
