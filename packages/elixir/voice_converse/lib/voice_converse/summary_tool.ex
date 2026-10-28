defmodule VoiceConverse.SummaryTool do
  @moduledoc "Validated, untrusted session summary categories supplied by the voice agent."

  alias VoiceConverse.{Config, Events}

  @fields ~w(decisions open_questions ideas)
  @max_items 20
  @max_text 500

  @spec spec() :: VoiceConverse.Provider.tool_spec()
  def spec do
    item = %{"type" => "string", "minLength" => 1, "maxLength" => @max_text}
    list = %{"type" => "array", "items" => item, "maxItems" => @max_items}

    %{
      name: "record_summary",
      description: "Before ending, record explicit decisions, unresolved questions and possible ideas separately.",
      parameters: %{
        "type" => "object",
        "properties" => Map.new(@fields, &{&1, list}),
        "required" => @fields,
        "additionalProperties" => false
      }
    }
  end

  @spec handle(map(), map()) :: {VoiceConverse.Tools.result(), map()}
  def handle(state, params) do
    case validate(params) do
      {:ok, summary} ->
        summary = Map.new(summary, fn {key, items} -> {key, Enum.map(items, &state.config.redactor.(&1))} end)
        state.event_broadcast.(state.subscribers, state.id, {:summary_recorded, summary})
        {%{text: "Summary recorded. End the conversation when ready.", is_error: false, end?: false}, state}

      {:error, :invalid_summary} ->
        {%{
           text:
             "Summary requires decisions, open_questions and ideas arrays, each with up to 20 nonblank strings of at most 500 characters.",
           is_error: true,
           end?: false
         }, state}
    end
  end

  @spec validate(term()) :: {:ok, map()} | {:error, :invalid_summary}
  def validate(params) when is_map(params) do
    if Enum.sort(Map.keys(params)) == Enum.sort(@fields) and Enum.all?(@fields, &valid_items?(params[&1])) do
      {:ok,
       %{
         decisions: Enum.map(params["decisions"], &String.trim/1),
         open_questions: Enum.map(params["open_questions"], &String.trim/1),
         ideas: Enum.map(params["ideas"], &String.trim/1)
       }}
    else
      {:error, :invalid_summary}
    end
  end

  def validate(_params), do: {:error, :invalid_summary}

  @spec redact_event(Config.t(), Events.ToolCall.t()) :: Events.ToolCall.t()
  def redact_event(config, %Events.ToolCall{name: "record_summary"} = event),
    do: %{event | params: redact(event.params, config.redactor)}

  def redact_event(_config, event), do: event

  defp valid_items?(items) when is_list(items),
    do: length(items) <= @max_items and Enum.all?(items, &valid_text?/1)

  defp valid_items?(_items), do: false

  defp valid_text?(text) when is_binary(text) and byte_size(text) <= @max_text * 4,
    do: String.trim(text) != "" and String.length(text) <= @max_text

  defp valid_text?(_text), do: false

  defp redact(value, redactor) when is_binary(value), do: redactor.(value)
  defp redact(value, redactor) when is_list(value), do: Enum.map(value, &redact(&1, redactor))

  defp redact(value, redactor) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact(item, redactor)} end)

  defp redact(value, _redactor), do: value
end
