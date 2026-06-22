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
  Resolve the config path by precedence: repo-local `./.aiur/config`, else the
  legacy repo-local `./.aiurconfig`, else the global `~/.aiur/config`, else the
  legacy global `~/.aiurconfig`. When none exist, returns the repo-local
  `./.aiur/config` (the new default) so the caller surfaces the "run aiur init"
  not-found error pointing at the current layout. When a global config is used it
  carries no repo — `Aiur.GitHub.Config.repo/0` auto-detects it from the cwd's
  git remote.
  """
  @spec detect_run_folder_config() :: Path.t()
  def detect_run_folder_config do
    resolve_config_path(config_path_candidates())
  end

  @doc false
  @spec config_path_candidates() :: [Path.t(), ...]
  def config_path_candidates do
    cwd = File.cwd!()
    home = Path.expand("~")

    [
      Path.join([cwd, @aiur_dir, @config_basename]),
      Path.join(cwd, @legacy_config_file_name),
      Path.join([home, @aiur_dir, @config_basename]),
      Path.join(home, @legacy_config_file_name)
    ]
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
    load(workflow_file_path())
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

  # `.aiurconfig` is pure YAML. An optional `prompt_file:` key points at a
  # sibling markdown template, resolved relative to the config file's directory.
  defp parse(content, path) do
    case yaml_to_map(content) do
      {:ok, config} ->
        case resolve_hooks(config, path) do
          {:ok, resolved} -> resolve_prompt(resolved, path)
          {:error, reason} -> {:error, reason}
        end

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  # An optional `hooks_file:` key points at a sibling YAML file (default
  # `.aiurhooks`) whose keys become the `hooks:` map, keeping multi-line hook
  # scripts out of the main config. When set it replaces any inline `hooks:`
  # block; when absent the inline block (if any) is used unchanged.
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
  Resolves the absolute `.aiurhooks` path referenced by `hooks_file:` in the
  config, or nil when none is set.

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
