defmodule Aiur.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias Aiur.WorkflowStore

  @workflow_file_name "WORKFLOW.md"
  @config_file_name ".aiurconfig"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:aiur, :workflow_file_path) || detect_run_folder_config()
  end

  defp detect_run_folder_config do
    cwd = File.cwd!()
    config_path = Path.join(cwd, @config_file_name)

    if File.regular?(config_path) do
      config_path
    else
      Path.join(cwd, @workflow_file_name)
    end
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

  # `.aiurconfig` is pure YAML: the whole file is config, with no prompt body.
  # `WORKFLOW.md` keeps front-matter + body semantics. Parse mode is keyed off
  # the filename, not fence presence, so a fence-less WORKFLOW.md stays all-body.
  defp parse(content, path) do
    if Path.basename(path) == @config_file_name do
      parse_pure_yaml(content)
    else
      parse_front_matter(content)
    end
  end

  defp parse_pure_yaml(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case front_matter_yaml_to_map(lines) do
      {:ok, config} ->
        {:ok, %{config: config, prompt: "", prompt_template: ""}}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp parse_front_matter(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
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
