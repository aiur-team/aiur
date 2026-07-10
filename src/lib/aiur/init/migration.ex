defmodule Aiur.Init.Migration do
  @moduledoc """
  Legacy root-layout migration for moving aiur files into `.aiur/`.

  The migration keeps the current move-order safety contract: copy referenced
  files first, write the rewritten config, then remove legacy originals and
  either track or gitignore the new folder.
  """

  alias Aiur.Init.Scaffold

  @aiurhooks_file_name "hooks"
  @prompt_basename "prompt.md"
  @examples_dir "examples"
  @gitignore_entry ".aiur/"
  @legacy_examples [
    {".aiurconfig.example", "config.example"},
    {".aiurhooks.example", "hooks.example"},
    {"AIUR.md.example", "prompt.md.example"}
  ]

  @doc """
  Migrate a legacy root-level aiur layout into the `.aiur/` folder. Copies the
  referenced hooks/prompt files and any `*.example` templates into `.aiur/`,
  writes the config to `.aiur/config` (rewriting `hooks_file:`/`prompt_file:` to
  the folder-relative names), and only then removes the legacy originals — so a
  partial failure never leaves a state aiur can't load. Tracked files are moved
  via git (and removed with `git rm`); with `ignore: true`, `.aiur/` is appended
  to `.gitignore` and the new files are left untracked. Settings are preserved
  verbatim apart from the two pointer values.
  """
  @spec migrate_layout(%{
          :legacy_config => Path.t(),
          :new_config => Path.t(),
          optional(:ignore) => boolean()
        }) :: {:ok, %{moved: [Path.t()]}} | {:error, term()}
  def migrate_layout(%{legacy_config: legacy_config, new_config: new_config} = opts) do
    ignore? = Map.get(opts, :ignore, false)
    base_dir = Path.dirname(legacy_config)
    new_dir = Path.dirname(new_config)
    git? = git_work_tree?(base_dir)

    raw = File.read!(legacy_config)
    config = parse_yaml(raw)

    File.mkdir_p!(new_dir)

    # Resolve the referenced pointer files. `pointer_src/2` only returns a source
    # that exists AND lives inside the repo — a `hooks_file:`/`prompt_file:` value
    # pointing outside the repo (absolute or `../` traversal, or `~/shared`) is
    # left in place, never copied or deleted.
    pointers = [
      {"hooks_file", pointer_src(base_dir, config["hooks_file"]), Path.join(new_dir, @aiurhooks_file_name)},
      {"prompt_file", pointer_src(base_dir, config["prompt_file"]), Path.join(new_dir, @prompt_basename)}
    ]

    pointer_moves = for {_key, src, dest} <- pointers, not is_nil(src), do: {src, dest}

    example_moves =
      for {legacy_name, new_name} <- @legacy_examples,
          src = Path.join(base_dir, legacy_name),
          File.regular?(src),
          do: {src, Path.join([new_dir, @examples_dir, new_name])}

    # 1. Copy content-preserving files into `.aiur/` (legacy left intact so far).
    copied =
      Enum.map(pointer_moves ++ example_moves, fn {src, dest} ->
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(src, dest)
        {src, dest}
      end)

    # 2. Write the rewritten config — the new layout is now complete and loadable.
    #    Only rewrite a pointer key whose file was actually migrated into `.aiur/`;
    #    a key whose source stayed put keeps its original value (still resolves).
    migrated_keys = for {key, src, _dest} <- pointers, not is_nil(src), do: key
    File.write!(new_config, rewrite_pointers(raw, migrated_keys))

    # 3. Remove the legacy originals (config last is implicit: it's only removed
    #    once `new_config` exists above).
    [legacy_config | Enum.map(copied, fn {src, _dest} -> src end)]
    |> Enum.each(&remove_path(&1, base_dir, git?))

    new_paths = [new_config | Enum.map(copied, fn {_src, dest} -> dest end)]

    # 4. Track the new files, or leave them untracked and gitignored.
    if ignore? do
      Scaffold.add_gitignore_entry(base_dir, @gitignore_entry)
    else
      if git?, do: git(base_dir, ["add", "--" | new_paths])
    end

    {:ok, %{moved: new_paths}}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  @spec pointer_src(Path.t(), String.t() | nil) :: Path.t() | nil
  def pointer_src(_base, value) when value in [nil, ""], do: nil

  def pointer_src(base, value) do
    src = Path.expand(value, base)
    if File.regular?(src) and inside?(base, src), do: src
  end

  # True when `path` is `base` itself or nested under it — guards the migration
  # against copying/deleting a pointer target that resolves outside the repo
  # (absolute, `~/...`, or `../` traversal).
  @doc false
  @spec inside?(Path.t(), Path.t()) :: boolean()
  def inside?(base, path) do
    base = Path.expand(base)
    path = Path.expand(path)
    path == base or String.starts_with?(path, base <> "/")
  end

  @doc false
  @spec rewrite_pointers(String.t(), [String.t()]) :: String.t()
  def rewrite_pointers(raw, keys) do
    new_value = %{"hooks_file" => @aiurhooks_file_name, "prompt_file" => @prompt_basename}
    Enum.reduce(keys, raw, fn key, acc -> replace_pointer_value(acc, key, new_value[key]) end)
  end

  # Rewrite the value of a top-level `key:` line, matching a double-quoted,
  # single-quoted, or bare token so a quoted value containing spaces is replaced
  # whole. Indented/nested keys and trailing inline comments are left untouched.
  @doc false
  @spec replace_pointer_value(String.t(), String.t(), String.t()) :: String.t()
  def replace_pointer_value(raw, key, new_value) do
    Regex.replace(~r/^(#{key}:[ \t]*)(?:"[^"]*"|'[^']*'|\S+)/m, raw, "\\1#{new_value}")
  end

  @doc false
  @spec parse_yaml(String.t()) :: map()
  def parse_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc false
  @spec git_work_tree?(Path.t()) :: boolean()
  def git_work_tree?(dir) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) == "true"
      _ -> false
    end
  rescue
    _ -> false
  end

  # Remove a legacy file: `git rm` when tracked (keeps git's rename detection
  # against the freshly-added `.aiur/` copy), plain delete otherwise.
  @doc false
  @spec remove_path(Path.t(), Path.t(), boolean()) :: :ok | {:error, File.posix()}
  def remove_path(path, base_dir, true) do
    rel = Path.relative_to(path, base_dir)

    case git(base_dir, ["rm", "-q", "-f", "--", rel]) do
      :ok -> :ok
      :error -> File.rm(path)
    end
  end

  def remove_path(path, _base_dir, false), do: File.rm(path)

  @doc false
  @spec git(Path.t(), [String.t()]) :: :ok | :error
  def git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
