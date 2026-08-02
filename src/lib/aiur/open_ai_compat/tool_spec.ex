defmodule Aiur.OpenAICompat.ToolSpec do
  @moduledoc false

  alias Aiur.Codex.DynamicTool

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

  @type validation_error ::
          :arguments_not_object
          | {:invalid_argument_types, [String.t()]}
          | {:missing_required_arguments, [String.t()]}
          | {:unexpected_arguments, [String.t()]}
          | {:unsupported_tool, String.t()}

  @spec specs(:chat_completions | :responses) :: [map()]
  def specs(:chat_completions) do
    Enum.map(all(), fn spec ->
      %{"type" => "function", "function" => Map.take(spec, ["name", "description", "parameters"])}
    end)
  end

  def specs(:responses) do
    Enum.map(all(), fn spec ->
      spec
      |> Map.take(["name", "description", "parameters"])
      |> Map.put("type", "function")
    end)
  end

  @spec decode_and_validate(String.t(), term()) :: {:ok, map()} | {:error, validation_error()}
  def decode_and_validate(name, arguments) do
    with {:ok, arguments} <- decode_arguments(arguments),
         {:ok, schema} <- fetch_schema(name),
         :ok <- validate_schema(arguments, schema) do
      {:ok, arguments}
    end
  end

  @spec format_validation_error(validation_error()) :: String.t()
  def format_validation_error(:arguments_not_object), do: "arguments must be a JSON object"

  def format_validation_error({:unsupported_tool, name}),
    do: "unsupported tool #{inspect(name)}"

  def format_validation_error({:missing_required_arguments, names}),
    do: "missing required arguments: #{Enum.join(names, ", ")}"

  def format_validation_error({:unexpected_arguments, names}),
    do: "unexpected arguments: #{Enum.join(names, ", ")}"

  def format_validation_error({:invalid_argument_types, names}),
    do: "invalid arguments: #{Enum.join(names, ", ")}"

  defp all, do: @builtin ++ DynamicTool.tool_specs()

  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :arguments_not_object}
    end
  end

  defp decode_arguments(_arguments), do: {:error, :arguments_not_object}

  defp fetch_schema(name) do
    Enum.find_value(all(), {:error, {:unsupported_tool, name}}, fn spec ->
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
      missing != [] -> {:error, {:missing_required_arguments, missing}}
      unexpected != [] -> {:error, {:unexpected_arguments, unexpected}}
      invalid != [] -> {:error, {:invalid_argument_types, Enum.map(invalid, &elem(&1, 0))}}
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
  defp valid_type?(_value, _type), do: true
end
