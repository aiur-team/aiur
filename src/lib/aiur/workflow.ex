defmodule Aiur.Workflow do
  @moduledoc """
  Loads workflow configuration and the agent prompt from the aiur config file.

  Config lives in a `.aiur/` folder (`.aiur/config`). The file is pure YAML. An optional
  `prompt_file:` key points at a markdown Liquid template (resolved relative to
  the config file's directory) that becomes the per-repo agent prompt. When
  `prompt_file:` is absent the prompt falls back to the built-in default template.
  """

  alias Aiur.WorkflowStore

  @aiur_dir ".aiur"
  @config_basename "config"
  @legacy_config_file_name ".aiurconfig"

  # Per-process config-path override, pinned by `set_workflow_file_path/1,2`
  # and dropped by `clear_workflow_file_path/0,1`. Lives in the process
  # dictionary so it is scoped to the process that set it and dies with it.
  @workflow_file_path_override_key :workflow_file_path_override

  @doc """
  The active config path, by precedence: a per-process override (pinned by
  `set_workflow_file_path/1,2`), then the VM-global `:workflow_file_path` app
  env, then run-folder discovery.

  The per-process override is what makes the path injectable per test (#2287).
  The path used to live only in the VM-global app env, so every concurrent
  `use Aiur.TestSupport` case re-pointed the same global key from its `setup` —
  one test's write-then-read could observe another test's config. A process
  that calls `set_workflow_file_path/1,2` now pins its own view in its process
  dictionary, so its reads stay stable even while a sibling test clobbers the
  global env. The override is process-scoped and dies with the process, so
  background workers and teardown processes never inherit a test's pin.
  """
  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Process.get(@workflow_file_path_override_key) ||
      Application.get_env(:aiur, :workflow_file_path) ||
      detect_run_folder_config()
  end

  @doc """
  Resolve the config path by precedence: repo-local `./.aiur/config`, then global
  `~/.aiur/config`. A legacy `.aiurconfig` at either level is detected only to
  raise an actionable error before a broader fallback can silently take over.
  When no config exists, returns repo-local `./.aiur/config` so the caller points
  at the canonical layout. A global config carries no repo —
  `Aiur.GitHub.Config.repo/0` auto-detects it from the cwd's git remote.
  """
  @spec detect_run_folder_config() :: Path.t()
  def detect_run_folder_config do
    resolve_config_path(config_path_candidates())
  end

  @doc false
  @spec config_path_candidates() :: [Path.t(), ...]
  def config_path_candidates do
    cwd = File.cwd!()
    home = home_dir()

    [
      Path.join([cwd, @aiur_dir, @config_basename]),
      Path.join(cwd, @legacy_config_file_name),
      Path.join([home, @aiur_dir, @config_basename]),
      Path.join(home, @legacy_config_file_name)
    ]
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
  def resolve_config_path([repo_config, repo_legacy, global_config, global_legacy]) do
    cond do
      File.regular?(repo_config) -> repo_config
      File.regular?(repo_legacy) -> raise_legacy_config!(repo_legacy)
      File.regular?(global_config) -> global_config
      File.regular?(global_legacy) -> raise_legacy_config!(global_legacy)
      true -> repo_config
    end
  end

  def resolve_config_path([default | _] = candidates) do
    Enum.find(candidates, default, &File.regular?/1)
  end

  defp raise_legacy_config!(legacy), do: raise(ArgumentError, legacy_config_error(legacy))

  @doc """
  Points the config path at `path`, both in the calling process (a per-process
  override) and in the VM-global `:workflow_file_path` app env.

  The app-env write keeps the historical production contract — the `WorkflowStore`
  and other processes resolve the path from the global env — while the
  process-scoped write keeps the calling process's own reads stable against a
  concurrent re-pointing of the global env (the #2287 test race). The override
  is scoped to the calling process and dies with it.

  Accepts `reload: false` to move the path without forcing the shared
  `WorkflowStore` cache to reload — used when the caller deliberately wants to
  leave the store's cache pointing at the previous path (exercising the #2133
  read fence) or when the store should reload from disk on its own poll.
  """
  @spec set_workflow_file_path(Path.t()) :: :ok
  @spec set_workflow_file_path(Path.t(), keyword()) :: :ok
  def set_workflow_file_path(path, opts \\ []) when is_binary(path) do
    Process.put(@workflow_file_path_override_key, path)
    Application.put_env(:aiur, :workflow_file_path, path)
    if Keyword.get(opts, :reload, true), do: maybe_reload_store()
    :ok
  end

  @doc """
  Removes the per-process config-path override and the VM-global
  `:workflow_file_path` app env, restoring run-folder discovery.

  Accepts `reload: false` to skip forcing the shared `WorkflowStore` cache
  reload, mirroring `set_workflow_file_path/2`.
  """
  @spec clear_workflow_file_path() :: :ok
  @spec clear_workflow_file_path(keyword()) :: :ok
  def clear_workflow_file_path(opts \\ []) do
    Process.delete(@workflow_file_path_override_key)
    Application.delete_env(:aiur, :workflow_file_path)
    if Keyword.get(opts, :reload, true), do: maybe_reload_store()
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

  @doc """
  Like `current/0`, but also returns the `WorkflowStore` generation the value
  came from — or `:unknown` when the store is not running and the config was
  read straight from disk. Callers use the generation to memoize derived work
  (see `Aiur.Config.settings/0`) without re-deriving it on every read.
  """
  @spec current_with_generation() :: {:ok, loaded_workflow(), pos_integer() | :unknown} | {:error, term()}
  def current_with_generation do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current_with_generation()

      _ ->
        with {:ok, workflow} <- load(), do: {:ok, workflow, :unknown}
    end
  end

  @doc false
  @spec current_with_cache_identity() ::
          {:ok, loaded_workflow(), pos_integer() | :unknown, reference() | :unknown} | {:error, term()}
  def current_with_cache_identity do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current_with_cache_identity()

      _ ->
        with {:ok, workflow} <- load(), do: {:ok, workflow, :unknown, :unknown}
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    if legacy_config_path?(path) do
      {:error, legacy_config_error(path)}
    else
      case File.read(path) do
        {:ok, content} ->
          parse(content, path)

        {:error, reason} ->
          {:error, {:missing_workflow_file, path, reason}}
      end
    end
  end

  @doc false
  @spec legacy_config_path?(Path.t()) :: boolean()
  def legacy_config_path?(path), do: String.ends_with?(Path.basename(path), ".aiurconfig")

  @doc false
  @spec legacy_config_error(Path.t()) :: String.t()
  def legacy_config_error(path) do
    destination =
      if Path.basename(path) == ".aiurconfig" do
        Path.join([Path.dirname(path), ".aiur", "config"])
      else
        Path.rootname(path, ".aiurconfig") <> ".yaml"
      end

    "#{path} is no longer supported. Move it to #{destination}. " <>
      "Keep relative prompt_file and hooks_file paths valid from the new config directory."
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

  # The config is pure YAML. An optional `prompt_file:` key points at a
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
