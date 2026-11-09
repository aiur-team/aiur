defmodule Aiur.Gateway.StateMigration do
  @moduledoc """
  One-time move of per-repository state from a single-project key to the gateway key:
  `<state root>/<old key>/<leaf>` becomes `<state root>/<gateway key>/<downcased leaf>`,
  leaving a symlink at the old path so a rollback to single-project mode still finds it.

  `plan/2` only reads the filesystem; `apply_plan/2` performs the plan.
  """

  alias Aiur.Config.Paths

  @type row :: %{kind: atom(), repo: String.t(), src: Path.t() | nil, dst: Path.t() | nil, detail: String.t() | nil}

  @aux_not_migrated [
    {"secret_key_base", "dashboard mints a new one"},
    {"config-overrides.json", "run-time overrides, re-apply with aiur set"}
  ]

  @doc """
  Options: `:state_root`, `:gateway_key`, `:home`, `:from_key` (legacy key for projects whose key
  cannot be derived from a config path, i.e. the global config).
  """
  @spec plan([%{repo: String.t(), config: Path.t()}], keyword()) :: [row()]
  def plan(projects, opts) do
    rows = projects |> Enum.map(&project_row(&1, opts)) |> mark_collisions()
    rows ++ aux_rows(projects, opts, rows)
  end

  defp project_row(%{repo: repo, config: config}, opts) do
    root = opts[:state_root]
    leaf = repo |> String.downcase() |> String.split("/") |> List.last() |> Paths.sanitize()
    dst = Path.join([root, opts[:gateway_key], leaf])

    case old_key(config, opts) do
      nil -> row(:skipped, repo, nil, dst, "legacy key not derivable; pass --from-key <hex10>")
      old_key -> classify(repo, Path.join(root, old_key), leaf, dst, old_key == opts[:gateway_key])
    end
  end

  defp old_key(config, opts) do
    project_root = config |> Path.expand() |> Path.dirname() |> Path.dirname()

    if project_root == Path.expand(opts[:home]) do
      opts[:from_key]
    else
      :sha256 |> :crypto.hash(real_path(project_root)) |> Base.encode16(case: :lower) |> binary_part(0, 10)
    end
  end

  # The launcher keys by `pwd -P`; keep the literal path for a root that is gone.
  defp real_path(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out, "\n")
      _ -> path
    end
  end

  defp classify(repo, old_dir, leaf, dst, same_key?) do
    case matching_dirs(old_dir, leaf) do
      [] -> if File.exists?(dst), do: row(:already_migrated, repo, nil, dst), else: row(:nothing, repo, nil, dst)
      [_, _ | _] = many -> row(:conflict, repo, nil, dst, "state exists as #{Enum.join(many, " and ")}")
      [name] -> classify_entry(repo, Path.join(old_dir, name), dst, same_key?)
    end
  end

  defp matching_dirs(dir, leaf) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&(String.downcase(&1) == leaf)) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp classify_entry(repo, src, dst, same_key?) do
    cond do
      src == dst -> row(:already_migrated, repo, src, dst)
      same_key? -> row(:move, repo, src, dst)
      File.read_link(src) == {:ok, dst} -> row(:already_migrated, repo, src, dst)
      match?({:ok, %File.Stat{type: :symlink}}, File.lstat(src)) -> row(:conflict, repo, src, dst, "#{src} is a symlink to somewhere else")
      File.exists?(dst) -> row(:conflict, repo, src, dst, "#{src} and #{dst} both exist")
      true -> row(:move, repo, src, dst)
    end
  end

  # Two projects landing on one downcased leaf is exactly what daemon boot refuses.
  defp mark_collisions(rows) do
    shared = rows |> Enum.group_by(& &1.dst) |> Map.filter(fn {_, group} -> length(group) > 1 end)

    Enum.map(rows, fn r ->
      case shared[r.dst] do
        nil -> r
        group -> %{r | kind: :conflict, detail: "#{Enum.map_join(group, " and ", & &1.repo)} share #{r.dst}"}
      end
    end)
  end

  defp aux_rows(projects, opts, rows) do
    keys =
      for {%{config: config}, %{kind: kind}} <- Enum.zip(projects, rows),
          kind in [:move, :already_migrated],
          key = old_key(config, opts),
          do: key

    base = Path.join([opts[:home], ".aiur", "instances"])
    dst = Path.join([base, opts[:gateway_key], "streamdeck-settings.json"])
    src = Enum.find_value(keys, fn key -> existing(Path.join([base, key, "streamdeck-settings.json"])) end)
    copy = if src && not File.exists?(dst), do: [row(:copy, "streamdeck-settings.json", src, dst)], else: []

    skipped =
      for {file, why} <- @aux_not_migrated, key <- Enum.uniq(keys), File.exists?(Path.join([base, key, file])) do
        row(:not_migrated, file, Path.join([base, key, file]), nil, why)
      end

    copy ++ skipped
  end

  defp existing(path), do: if(File.regular?(path), do: path)

  defp row(kind, repo, src, dst, detail \\ nil), do: %{kind: kind, repo: repo, src: src, dst: dst, detail: detail}

  @doc """
  Performs a plan. `live?` is a zero-arity function returning true when a daemon is up.
  Returns `:ok`, `{:error, :daemon_running}`, `{:error, {:conflict, rows}}` or `{:error, {:io, path, reason}}`.
  """
  @spec apply_plan([row()], (-> boolean())) :: :ok | {:error, term()}
  def apply_plan(rows, live?) do
    cond do
      Enum.any?(rows, &(&1.kind == :conflict)) -> {:error, {:conflict, Enum.filter(rows, &(&1.kind == :conflict))}}
      live?.() -> {:error, :daemon_running}
      true -> Enum.reduce_while(rows, :ok, fn row, :ok -> step(row) end)
    end
  end

  defp step(%{kind: :move, src: src, dst: dst}) do
    result =
      with :ok <- File.mkdir_p(Path.dirname(dst)),
           :ok <- File.chmod(Path.dirname(dst), 0o700),
           :ok <- rename(src, dst) do
        if Path.dirname(src) == Path.dirname(dst), do: :ok, else: File.ln_s(dst, src)
      end

    done(result, src)
  end

  defp step(%{kind: :copy, src: src, dst: dst}) do
    done(with(:ok <- File.mkdir_p(Path.dirname(dst)), do: File.cp(src, dst)), dst)
  end

  defp step(_row), do: {:cont, :ok}

  # A case-only rename in one directory goes through a temporary name so a case-insensitive filesystem accepts it.
  defp rename(src, dst) do
    if Path.dirname(src) == Path.dirname(dst) do
      tmp = Path.join(Path.dirname(dst), "." <> Path.basename(dst) <> ".migrating")
      with :ok <- File.rename(src, tmp), do: File.rename(tmp, dst)
    else
      File.rename(src, dst)
    end
  end

  defp done(:ok, _path), do: {:cont, :ok}
  defp done({:error, reason}, path), do: {:halt, {:error, {:io, path, reason}}}
end
