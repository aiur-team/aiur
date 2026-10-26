defmodule VoiceConverse.Tools do
  @moduledoc """
  Read-only tools a provider may invoke during a conversation.

  Hosts decide which detail sections exist through `BriefingSource.sections/1`.
  The router returns a small, redacted summary; the session owns transcript
  persistence and delivery to the provider.
  """

  alias VoiceConverse.{Briefing, Config, Events, Ports}

  @max_summary_chars 1_500

  @type result :: %{text: String.t(), is_error: boolean(), end?: boolean()}

  @spec specs(Config.t(), term()) :: [VoiceConverse.Provider.tool_spec()]
  def specs(%Config{} = config, target) do
    [status_spec()] ++ detail_specs(config.briefing_source, target) ++ command_specs(config) ++ [end_spec()]
  end

  @spec handle(map(), Events.ToolCall.t()) :: result()
  def handle(%{config: config, target: target}, %Events.ToolCall{name: "get_status"}),
    do: get_status(config, target)

  def handle(%{config: config, target: target}, %Events.ToolCall{name: "get_details", params: params}),
    do: get_details(config, target, params)

  # This stays callable when the optional port is absent so a stale provider
  # specification says that Command data is unavailable rather than implying
  # there are no Commands.
  def handle(%{config: config, target: target}, %Events.ToolCall{name: "list_open_commands"}),
    do: list_open_commands(config, target)

  def handle(_session, %Events.ToolCall{name: "end_conversation"}), do: result("Ending.", nil, end?: true)
  def handle(_session, %Events.ToolCall{}), do: result("Unknown tool.", nil, is_error: true)

  defp get_status(config, target) do
    case Ports.call_port(config.briefing_source, :brief, [target], :brief) do
      {:ok, %Briefing{} = briefing} ->
        {text, _meta} = Briefing.render(briefing, budget: config.limits.briefing_token_budget)
        result(String.replace(text, "\n", "; "), config)

      _ ->
        result("Status data unavailable.", config)
    end
  end

  defp get_details(config, target, params) do
    section = param(params, "section")

    if section in section_ids(config.briefing_source, target) do
      opts = [n: clamp_n(param(params, "n"))]

      case Ports.call_port(config.briefing_source, :details, [target, section, opts], :details) do
        {:ok, text} when is_binary(text) and text != "" -> result(text, config)
        _ -> result("Details data unavailable.", config)
      end
    else
      result("Unknown detail section.", config, is_error: true)
    end
  end

  defp list_open_commands(%Config{command_source: nil} = config, _target),
    do: result("Command data unavailable.", config)

  defp list_open_commands(%Config{command_source: source} = config, target) do
    case Ports.call_port(source, :open, [target], :fetch) do
      {:ok, commands} when is_list(commands) -> result(commands_text(commands), config)
      _ -> result("Command data unavailable.", config)
    end
  end

  defp commands_text([]), do: "No open Commands."

  defp commands_text(commands) do
    commands
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn
      {command, index} when is_map(command) ->
        id = map_value(command, :id, "unknown")
        question = map_value(command, :question, "")
        options = map_value(command, :options, [])
        "#{index}. #{id}: #{question} (#{Enum.map_join(options, ", ", &option_label/1)})"

      {_command, index} ->
        "#{index}. Command data unavailable"
    end)
  end

  defp option_label(%{label: label}), do: to_string(label)
  defp option_label(%{"label" => label}), do: to_string(label)
  defp option_label(label) when is_binary(label), do: label
  defp option_label(label), do: inspect(label)

  defp status_spec do
    %{name: "get_status", description: "Read the current status.", parameters: empty_parameters()}
  end

  defp detail_specs(source, target) do
    case section_ids(source, target) do
      [] ->
        []

      sections ->
        [%{name: "get_details", description: "Read a current detail section.", parameters: detail_parameters(sections)}]
    end
  end

  defp command_specs(%Config{command_source: nil}), do: []

  defp command_specs(%Config{}),
    do: [%{name: "list_open_commands", description: "List open operator Commands.", parameters: empty_parameters()}]

  defp end_spec,
    do: %{
      name: "end_conversation",
      description: "End this conversation after replying.",
      parameters: empty_parameters()
    }

  defp empty_parameters, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  defp detail_parameters(sections) do
    %{
      "type" => "object",
      "properties" => %{
        "section" => %{"type" => "string", "enum" => sections},
        "n" => %{"type" => "integer", "minimum" => 1, "maximum" => 30, "default" => 10}
      },
      "required" => ["section"],
      "additionalProperties" => false
    }
  end

  defp section_ids(source, target) do
    case Ports.call_port(source, :sections, [target], :details) do
      sections when is_list(sections) ->
        Enum.flat_map(sections, fn
          %{id: id} when is_binary(id) -> [id]
          %{"id" => id} when is_binary(id) -> [id]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp param(params, "section") when is_map(params), do: Map.get(params, "section", Map.get(params, :section))
  defp param(params, "n") when is_map(params), do: Map.get(params, "n", Map.get(params, :n))
  defp param(_params, _key), do: nil

  defp clamp_n(n) when is_integer(n), do: min(max(n, 1), 30)
  defp clamp_n(_n), do: 10

  defp map_value(map, atom_key, default), do: Map.get(map, atom_key, Map.get(map, Atom.to_string(atom_key), default))

  defp result(text, config), do: result(text, config, [])

  defp result(text, config, opts) do
    text = if config, do: config.redactor.(text), else: text
    %{text: truncate(text), is_error: Keyword.get(opts, :is_error, false), end?: Keyword.get(opts, :end?, false)}
  end

  defp truncate(text) do
    if String.length(text) <= @max_summary_chars,
      do: text,
      else: String.slice(text, 0, @max_summary_chars - 1) <> "…"
  end
end
