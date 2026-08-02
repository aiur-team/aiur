defmodule Aiur.OpenAICompat.Tools do
  @moduledoc false

  alias Aiur.Codex.DynamicTool
  alias Aiur.OpenAICompat.CommandRunner

  @builtin [
    %{
      "name" => "read_file",
      "description" => "Read a UTF-8 file inside the current workspace.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "write_file",
      "description" => "Write complete UTF-8 contents to a file inside the current workspace.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}, "content" => %{"type" => "string"}},
        "required" => ["path", "content"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "replace_in_file",
      "description" => "Replace one exact text occurrence in a workspace file.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "old_text" => %{"type" => "string"},
          "new_text" => %{"type" => "string"}
        },
        "required" => ["path", "old_text", "new_text"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "list_files",
      "description" => "List workspace files matching a relative glob.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"glob" => %{"type" => "string"}},
        "required" => ["glob"],
        "additionalProperties" => false
      }
    },
    %{
      "name" => "exec_command",
      "description" => "Run a shell command in the current workspace through the configured OS sandbox.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"command" => %{"type" => "string"}},
        "required" => ["command"],
        "additionalProperties" => false
      }
    }
  ]

  @spec specs(:chat_completions | :responses) :: [map()]
  def specs(:chat_completions) do
    Enum.map(@builtin ++ DynamicTool.tool_specs(), fn spec ->
      %{"type" => "function", "function" => Map.take(spec, ["name", "description", "parameters"])}
    end)
  end

  def specs(:responses) do
    Enum.map(@builtin ++ DynamicTool.tool_specs(), fn spec ->
      spec
      |> Map.take(["name", "description", "parameters"])
      |> Map.put("type", "function")
    end)
  end

  @spec decode_and_validate(String.t(), term()) :: {:ok, map()} | {:error, String.t()}
  def decode_and_validate(name, arguments) do
    with {:ok, arguments} <- decode_arguments(arguments),
         {:ok, schema} <- fetch_schema(name),
         :ok <- validate_schema(arguments, schema) do
      {:ok, arguments}
    end
  end

  @spec execute(String.t(), map(), map(), keyword()) :: map()
  def execute("read_file", %{"path" => path}, context, _opts) do
    with {:ok, absolute} <- workspace_path(context.workspace, path),
         {:ok, contents} <- File.read(absolute) do
      success(contents)
    else
      {:error, reason} -> failure(format_reason(reason))
    end
  end

  def execute("write_file", %{"path" => path, "content" => content}, context, _opts) do
    with {:ok, absolute} <- workspace_path(context.workspace, path),
         :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, content) do
      success("wrote #{path}")
    else
      {:error, reason} -> failure(format_reason(reason))
    end
  end

  def execute("replace_in_file", %{"path" => path, "old_text" => old, "new_text" => new}, context, _opts) do
    with {:ok, absolute} <- workspace_path(context.workspace, path),
         {:ok, contents} <- File.read(absolute),
         :ok <- unique_occurrence(contents, old),
         :ok <- File.write(absolute, String.replace(contents, old, new)) do
      success("updated #{path}")
    else
      {:error, reason} -> failure(format_reason(reason))
    end
  end

  def execute("list_files", %{"glob" => glob}, context, _opts) do
    case workspace_path(context.workspace, glob) do
      {:ok, pattern} ->
        files =
          pattern
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&match?({:ok, _path}, workspace_path(context.workspace, Path.relative_to(&1, context.workspace))))
          |> Enum.take(2_000)
          |> Enum.map(&Path.relative_to(&1, context.workspace))

        success(Enum.join(files, "\n"))

      {:error, reason} ->
        failure(format_reason(reason))
    end
  end

  def execute("exec_command", %{"command" => command}, context, opts),
    do: CommandRunner.run(context.workspace, command, opts)

  def execute(name, arguments, context, _opts) do
    case context.tool_executor do
      fun when is_function(fun, 2) -> fun.(name, arguments)
      _ -> failure("dynamic tool executor unavailable for #{name}")
    end
  end

  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, "arguments must be a JSON object"}
    end
  end

  defp decode_arguments(_), do: {:error, "arguments must be a JSON object"}

  defp fetch_schema(name) do
    Enum.find_value(@builtin ++ DynamicTool.tool_specs(), {:error, "unsupported tool #{inspect(name)}"}, fn spec ->
      if spec["name"] == name, do: {:ok, spec["parameters"]}
    end)
  end

  defp validate_schema(arguments, schema) do
    required = schema["required"] || []
    properties = schema["properties"] || %{}
    missing = Enum.reject(required, &Map.has_key?(arguments, &1))
    unexpected = if schema["additionalProperties"] == false, do: Map.keys(arguments) -- Map.keys(properties), else: []
    invalid = Enum.filter(arguments, fn {key, value} -> not valid_type?(value, get_in(properties, [key, "type"])) end)

    cond do
      missing != [] -> {:error, "missing required arguments: #{Enum.join(missing, ", ")}"}
      unexpected != [] -> {:error, "unexpected arguments: #{Enum.join(unexpected, ", ")}"}
      invalid != [] -> {:error, "invalid arguments: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}"}
      true -> :ok
    end
  end

  defp valid_type?(_value, nil), do: true
  defp valid_type?(value, "string"), do: is_binary(value)
  defp valid_type?(value, "integer"), do: is_integer(value)
  defp valid_type?(value, "number"), do: is_number(value)
  defp valid_type?(value, "boolean"), do: is_boolean(value)
  defp valid_type?(value, "object"), do: is_map(value)
  defp valid_type?(value, "array"), do: is_list(value)
  defp valid_type?(_value, _), do: true

  defp workspace_path(workspace, relative) when is_binary(relative) do
    root = Path.expand(workspace)
    path = Path.expand(relative, root)

    with true <- path == root or String.starts_with?(path, root <> "/"),
         :ok <- reject_symlink_components(root, path) do
      {:ok, path}
    else
      false -> {:error, :outside_workspace}
      {:error, _reason} = error -> error
    end
  end

  defp workspace_path(_workspace, _relative), do: {:error, :invalid_path}

  defp reject_symlink_components(root, path) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      candidate = Path.join(current, component)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_path}}
        {:ok, _stat} -> {:cont, candidate}
        {:error, :enoent} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _path_or_ok -> :ok
    end
  end

  defp unique_occurrence(_contents, ""), do: {:error, :empty_old_text}

  defp unique_occurrence(contents, old) do
    case :binary.matches(contents, old) do
      [_] -> :ok
      [] -> {:error, :old_text_not_found}
      _ -> {:error, :old_text_not_unique}
    end
  end

  defp success(output), do: %{"success" => true, "output" => output}
  defp failure(output), do: %{"success" => false, "output" => output}
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
