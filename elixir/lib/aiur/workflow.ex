defmodule Aiur.Workflow do
  @moduledoc """
  Loads workflow configuration and the agent prompt from `.aiurconfig`.

  `.aiurconfig` is pure YAML. An optional `prompt_file:` key points at a
  markdown Liquid template (resolved relative to the config file's directory)
  that becomes the per-repo agent prompt. When `prompt_file:` is absent the
  prompt falls back to the built-in default template.
  """

  alias Aiur.WorkflowStore

  @config_file_name ".aiurconfig"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:aiur, :workflow_file_path) || detect_run_folder_config()
  end

  @spec detect_run_folder_config() :: Path.t()
  def detect_run_folder_config do
    Path.join(File.cwd!(), @config_file_name)
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
        resolve_prompt(config, path)

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
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
