defmodule Aiur.OpenAICompat.Conversation do
  @moduledoc false

  @spec append_assistant(map(), map()) :: map()
  def append_assistant(%{config: %{transport: :responses}} = state, %{output: output})
      when is_list(output) do
    %{state | messages: state.messages ++ output}
  end

  def append_assistant(state, completion) do
    message =
      completion.message
      |> Map.put("role", "assistant")
      |> maybe_put_reasoning(completion, state.config)
      |> maybe_put_tool_calls(completion.tool_calls)

    %{state | messages: state.messages ++ [message]}
  end

  @spec append_tool_result(map(), map(), String.t()) :: map()
  def append_tool_result(state, call, output) do
    message =
      case state.config.transport do
        :responses -> %{"type" => "function_call_output", "call_id" => call.id, "output" => output}
        :chat_completions -> %{"role" => "tool", "tool_call_id" => call.id, "content" => output}
      end

    %{state | messages: state.messages ++ [message]}
  end

  defp maybe_put_reasoning(message, %{reasoning: reasoning}, %{quirks: %{reasoning_content_replay: true}})
       when is_binary(reasoning) and reasoning != "",
       do: Map.put(message, "reasoning_content", reasoning)

  defp maybe_put_reasoning(message, _completion, _config), do: Map.delete(message, "reasoning_content")

  defp maybe_put_tool_calls(message, []), do: Map.delete(message, "tool_calls")

  defp maybe_put_tool_calls(message, calls) do
    formatted =
      Enum.map(calls, fn call ->
        %{
          "id" => call.id,
          "type" => "function",
          "function" => %{"name" => call.name, "arguments" => encode_arguments(call.arguments)}
        }
      end)

    Map.put(message, "tool_calls", formatted)
  end

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp encode_arguments(_arguments), do: "{}"
end
