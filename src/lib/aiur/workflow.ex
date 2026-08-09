defmodule Aiur.Workflow do
  @moduledoc """
  Loads workflow configuration and the agent prompt from the aiur config file.

  Config lives in a `.aiur/` folder (`.aiur/config`) with a backward-compatible
  fallback to the legacy root `.aiurconfig`. The file is pure YAML. An optional
  `prompt_file:` key points at a markdown Liquid template (resolved relative to
  the config file's directory) that becomes the per-repo agent prompt. When
  `prompt_file:` is absent the prompt falls back to the built-in default template.
  """

  alias Aiur.WorkflowStore

  # New layout: config lives at `.aiur/config`; legacy layout is the root
  # `.aiurconfig` dotfile. Both are honored on read (discovery falls back).
  @aiur_dir ".aiur"
  @config_basename "config"
  @legacy_config_file_name ".aiurconfig"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:aiur, :workflow_file_path) || detect_run_folder_config()
  end

  @doc """
  Resolve the config path by walking from the current directory to the
  filesystem root. At each level `.aiur/config` wins over the legacy
  `.aiurconfig`; only after exhausting repository ancestors does discovery try
  the two global paths. When none exist, returns the cwd-local `.aiur/config` so
  path-only callers retain a useful scaffold destination. `load/0` reports the
  complete searched-path set instead of attempting that absent destination.
  """
  @spec detect_run_folder_config() :: Path.t()
  def detect_run_folder_config do
    resolve_config_path(config_path_candidates())
  end

  @doc false
  @spec discover_config_path() :: {:ok, Path.t()} | {:error, term()}
  def discover_config_path do
    cwd = File.cwd!()
    candidates = config_path_candidates()

    case Enum.find(candidates, &File.regular?/1) do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, {:missing_workflow_file, %{cwd: cwd, searched_paths: candidates}}}
    end
  end

  @doc false
  @spec config_path_candidates() :: [Path.t(), ...]
  def config_path_candidates do
    cwd = File.cwd!()
    home = home_dir()

    cwd
    |> ancestor_directories()
    |> Enum.flat_map(fn dir ->
      [
        Path.join([dir, @aiur_dir, @config_basename]),
        Path.join(dir, @legacy_config_file_name)
      ]
    end)
    |> Kernel.++([
      Path.join([home, @aiur_dir, @config_basename]),
      Path.join(home, @legacy_config_file_name)
    ])
    |> Enum.uniq()
  end

  defp ancestor_directories(path), do: ancestor_directories(Path.expand(path), [])

  defp ancestor_directories(path, acc) do
    parent = Path.dirname(path)
    next = [path | acc]

    if parent == path,
      do: Enum.reverse(next),
      else: ancestor_directories(parent, next)
  end

  # Read HOME at call time rather than via `Path.expand("~")`, which resolves
  # the home the VM captured at boot and ignores any later `System.put_env`.
  # The test helper sandboxes HOME precisely so a suite run cannot discover the
  # developer's real `~/.aiur/config` — with the cached expansion that sandbox
  # silently did nothing, and background pollers issued real tracker requests
  # against whatever account the developer had configured.
  defp home_dir do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" -> home
      _unset -> Path.expand("~")
    end
  end

  @doc false
  @spec resolve_config_path([Path.t(), ...]) :: Path.t()
  def resolve_config_path([default | _] = candidates) do
    Enum.find(candidates, default, &File.regular?/1)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:aiur, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:aiur, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    case load_with_path() do
      {:ok, _path, workflow} -> {:ok, workflow}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec load_with_path() :: {:ok, Path.t(), loaded_workflow()} | {:error, term()}
  def load_with_path do
    case Application.get_env(:aiur, :workflow_file_path) do
      path when is_binary(path) and path != "" ->
        load_with_path(path)

      _unset ->
        load_discovered_config()
    end
  end

  defp load_discovered_config do
    case discover_config_path() do
      {:ok, path} -> load_with_path(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_with_path(path) do
    case load(path) do
      {:ok, workflow} -> {:ok, path, workflow}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content, path)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @doc false
  @spec resolved_prewarm_file_path(Path.t()) :: Path.t() | nil
  def resolved_prewarm_file_path(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, config} <- yaml_to_map(content),
         %{} = prewarm <- Map.get(config, "prewarm"),
         rel when is_binary(rel) and rel != "" <- Map.get(prewarm, "base_build_file") do
      Path.expand(rel, Path.dirname(path))
    else
      _ -> nil
    end
  end

  # `.aiurconfig` is pure YAML. An optional `prompt_file:` key points at a
  # sibling markdown template, resolved relative to the config file's directory.
  defp parse(content, path) do
    case yaml_to_map(content) do
      {:ok, config} ->
        with {:ok, config} <- resolve_hooks(config, path),
             {:ok, config} <- resolve_prewarm(config, path),
             {:ok, config} <- resolve_alerts(config, path) do
          resolve_prompt(config, path)
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  # An optional `hooks_file:` key points at a sibling YAML file (`hooks`, resolved
  # relative to the config directory) whose keys become the `hooks:` map, keeping
  # multi-line hook scripts out of the main config. When set it replaces any inline
  # `hooks:` block; when absent the inline block (if any) is used unchanged.
  defp resolve_hooks(config, path) do
    case Map.get(config, "hooks_file") do
      rel when is_binary(rel) and rel != "" ->
        resolved = Path.expand(rel, Path.dirname(path))

        case read_hooks_file(resolved) do
          {:ok, hooks} -> {:ok, Map.put(config, "hooks", hooks)}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, config}
    end
  end

  # Split the read from the parse so a missing/unreadable file and a malformed
  # (or non-map) one get distinct errors. yaml_to_map returns
  # {:error, :workflow_front_matter_not_a_map} for non-map YAML, so a successful
  # decode is always a map — no non-map success case to handle.
  defp read_hooks_file(resolved) do
    case File.read(resolved) do
      {:ok, content} ->
        case yaml_to_map(content) do
          {:ok, hooks} -> {:ok, hooks}
          {:error, reason} -> {:error, {:invalid_hooks_file, resolved, reason}}
        end

      {:error, reason} ->
        {:error, {:missing_hooks_file, resolved, reason}}
    end
  end

  # An optional `base_build_file:` under `prewarm:` points at a sibling script
  # (convention `prewarm`, resolved relative to the config dir) whose raw shell
  # contents become `prewarm.base_build` — keeping the multi-line build command
  # out of the main config, mirroring `hooks_file`. When absent, an inline
  # `base_build:` (if any) is used unchanged.
  defp resolve_prewarm(config, path) do
    with %{} = prewarm <- Map.get(config, "prewarm"),
         rel when is_binary(rel) and rel != "" <- Map.get(prewarm, "base_build_file") do
      resolved = Path.expand(rel, Path.dirname(path))

      case File.read(resolved) do
        {:ok, content} ->
          {:ok, put_in(config, ["prewarm", "base_build"], String.trim(content))}

        {:error, reason} ->
          {:error, {:missing_prewarm_file, resolved, reason}}
      end
    else
      _ -> {:ok, config}
    end
  end

  # An optional `alerts.alerts_file:` key points at a sibling topic→sound mapping
  # file (convention `.aiur/alerts`). A *relative* value is anchored to the config
  # dir — mirroring `hooks_file`/`prompt_file` — so `alerts_file: alerts` resolves
  # next to the config regardless of the daemon's cwd. Absolute and `~/` paths are
  # left untouched (expanded later by `Aiur.Alerts`); an absent or empty value is
  # left as-is so the bundled `.aiur/alerts` fallback still applies. The pointed-at
  # file is read lazily at emit time, so a missing file is not an error here.
  defp resolve_alerts(config, path) do
    with %{} = alerts <- Map.get(config, "alerts"),
         rel when is_binary(rel) and rel != "" <- Map.get(alerts, "alerts_file"),
         true <- relative_alerts_file?(rel) do
      resolved = Path.expand(rel, Path.dirname(path))
      {:ok, put_in(config, ["alerts", "alerts_file"], resolved)}
    else
      _ -> {:ok, config}
    end
  end

  # Absolute and `~/`-prefixed paths are honoured verbatim by `Aiur.Alerts`, so
  # only a relative value needs config-dir anchoring.
  defp relative_alerts_file?("/" <> _), do: false
  defp relative_alerts_file?("~/" <> _), do: false
  defp relative_alerts_file?(_rel), do: true

  defp resolve_prompt(config, path) do
    case Map.get(config, "prompt_file") do
      rel when is_binary(rel) and rel != "" ->
        resolved = Path.expand(rel, Path.dirname(path))

        case File.read(resolved) do
          {:ok, body} ->
            prompt = String.trim(body)
            {:ok, %{config: config, prompt: prompt, prompt_template: prompt}}

          {:error, reason} ->
            {:error, {:missing_prompt_file, resolved, reason}}
        end

      _ ->
        {:ok, %{config: config, prompt: "", prompt_template: ""}}
    end
  end

  @doc """
  Resolves the absolute path of the `prompt_file:` referenced by the config at
  `config_path`, or `nil` when the key is absent or the config cannot be read.
  Used by `WorkflowStore` to detect prompt-template edits during change polling.
  """
  @spec resolved_prompt_file_path(Path.t()) :: Path.t() | nil
  def resolved_prompt_file_path(config_path) when is_binary(config_path) do
    with {:ok, content} <- File.read(config_path),
         {:ok, config} <- yaml_to_map(content),
         rel when is_binary(rel) and rel != "" <- Map.get(config, "prompt_file") do
      Path.expand(rel, Path.dirname(config_path))
    else
      _ -> nil
    end
  end

  @doc """
  Resolves the absolute path of the hooks file referenced by `hooks_file:` in the
  config (relative to the config directory), or nil when none is set.

  Used by `WorkflowStore` to detect hook-file edits during change polling.
  """
  @spec resolved_hooks_file_path(Path.t()) :: Path.t() | nil
  def resolved_hooks_file_path(config_path) when is_binary(config_path) do
    with {:ok, content} <- File.read(config_path),
         {:ok, config} <- yaml_to_map(content),
         rel when is_binary(rel) and rel != "" <- Map.get(config, "hooks_file") do
      Path.expand(rel, Path.dirname(config_path))
    else
      _ -> nil
    end
  end

  defp yaml_to_map(content) do
    if String.trim(content) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(content) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
