defmodule Aiur.OpenAICompat.Tools do
  @moduledoc false

  alias Aiur.OpenAICompat.{BoundedGlob, CommandRunner, ToolSpec, WorkspacePath}

  @spec specs(:chat_completions | :responses) :: [map()]
  defdelegate specs(transport), to: ToolSpec

  @type validation_error :: ToolSpec.validation_error()

  @spec decode_and_validate(String.t(), term()) :: {:ok, map()} | {:error, validation_error()}
  defdelegate decode_and_validate(name, arguments), to: ToolSpec

  @spec format_validation_error(validation_error()) :: String.t()
  defdelegate format_validation_error(error), to: ToolSpec

  @spec execute(String.t(), map(), map(), keyword()) :: map()
  def execute("read_file", %{"path" => path}, context, _opts) do
    with {:ok, absolute} <- WorkspacePath.resolve(context.workspace, path),
         {:ok, contents} <- File.read(absolute) do
      success(contents)
    else
      {:error, reason} -> failure(format_reason(reason))
    end
  end

  def execute("write_file", %{"path" => path, "content" => content}, context, _opts) do
    with {:ok, absolute} <- WorkspacePath.resolve(context.workspace, path),
         :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, content) do
      success("wrote #{path}")
    else
      {:error, reason} -> failure(format_reason(reason))
    end
  end

  def execute("replace_in_file", %{"path" => path, "old_text" => old, "new_text" => new}, context, _opts) do
    with {:ok, absolute} <- WorkspacePath.resolve(context.workspace, path),
         {:ok, contents} <- File.read(absolute),
         :ok <- unique_occurrence(contents, old),
         :ok <- File.write(absolute, String.replace(contents, old, new)) do
      success("updated #{path}")
    else
      {:error, reason} -> failure(format_reason(reason))
    end
  end

  def execute("list_files", %{"glob" => glob}, context, _opts) do
    with {:ok, _pattern} <- WorkspacePath.resolve(context.workspace, glob),
         {:ok, files} <- BoundedGlob.list(context.workspace, glob, 2_000) do
      success(Enum.join(files, "\n"))
    else
      {:error, reason} -> failure(format_reason(reason))
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
