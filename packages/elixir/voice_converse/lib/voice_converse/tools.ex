defmodule VoiceConverse.Tools do
  @moduledoc """
  Provider tools a provider may invoke during a conversation.

  Hosts decide which detail sections exist through `BriefingSource.sections/1`.
  The router returns a small, redacted summary; the session owns transcript
  persistence and delivery to the provider.
  """

  alias VoiceConverse.{Briefing, Config, Events, Ports, SummaryTool}
  alias VoiceConverse.Ports.HostTools

  @max_summary_chars 1_500
  @type host_tool_spec :: %{name: String.t(), description: String.t(), params: map()}

  @type result :: %{text: String.t(), is_error: boolean(), end?: boolean()}

  @spec specs(Config.t(), term()) :: [VoiceConverse.Provider.tool_spec()]
  def specs(%Config{} = config, target), do: specs(config, target, load_host_specs(config, target))

  @doc false
  @spec specs(Config.t(), term(), [host_tool_spec()]) :: [VoiceConverse.Provider.tool_spec()]
  def specs(%Config{} = config, target, host_tool_specs) do
    specs =
      [status_spec()] ++
        detail_specs(config.briefing_source, target) ++
        command_specs(config) ++
        [propose_instruction_spec()] ++
        ask_specs(config, target) ++ summary_specs(config) ++ [end_spec()] ++ normalize_host_specs(host_tool_specs)

    Enum.filter(specs, &allowed?(config, &1.name))
  end

  @doc "Enforces the host's tool allowlist before invoking a session tool."
  @spec dispatch(map(), Events.ToolCall.t(), (map(), Events.ToolCall.t() -> {result(), map()})) :: {result(), map()}
  def dispatch(state, event, handler) do
    if allowed?(state.config, event.name),
      do: dispatch_allowed(state, event, handler),
      else: {result("Tool is unavailable in this conversation.", state.config, is_error: true), state}
  end

  defp dispatch_allowed(state, %Events.ToolCall{name: "record_summary", params: params}, _handler),
    do: SummaryTool.handle(state, params)

  defp dispatch_allowed(
         %{config: %{host_tools: source}, host_tool_specs: host_tool_specs, target: target} = state,
         event,
         handler
       ) do
    if source && host_tool?(host_tool_specs, event.name) do
      case Ports.call_port(source, :call, [event.name, target, event.params], :host_tool) do
        {:ok, text} when is_binary(text) -> {result(text, state.config), state}
        _ -> {result("Host tool unavailable.", state.config, is_error: true), state}
      end
    else
      handler.(state, event)
    end
  end

  defp dispatch_allowed(state, event, handler), do: handler.(state, event)

  defp load_host_specs(%Config{host_tools: nil}, _target), do: []

  defp load_host_specs(%Config{host_tools: source}, target) do
    case Ports.call_port(source, :specs, [target], :host_tool) do
      {:ok, specs} when is_list(specs) ->
        specs

      _ ->
        []
    end
  end

  defp normalize_host_specs(specs) do
    Enum.flat_map(specs, fn
      %{name: name, description: description, params: params}
      when is_binary(name) and name != "" and is_binary(description) and is_map(params) ->
        if HostTools.reserved_name?(name), do: [], else: [%{name: name, description: description, parameters: params}]

      _invalid ->
        []
    end)
  end

  defp host_tool?(specs, name) do
    not HostTools.reserved_name?(name) and Enum.any?(specs, &match?(%{name: ^name}, &1))
  end

  defp summary_specs(%Config{allowed_tools: tools}) when is_list(tools),
    do: if("record_summary" in tools, do: [SummaryTool.spec()], else: [])

  defp summary_specs(_config), do: []

  defp allowed?(%Config{allowed_tools: nil}, _name), do: true
  defp allowed?(%Config{allowed_tools: tools}, name), do: name in tools

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

  @doc false
  @spec proposed_instruction(map()) :: {:ok, String.t()} | {:error, result()}
  def proposed_instruction(params) do
    case param(params, "text") do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, result("Instruction text is required.", nil, is_error: true)}
    end
  end

  @doc false
  @spec draft_waiting(String.t()) :: result()
  def draft_waiting(draft_id),
    do: result("Draft #{draft_id} is waiting for the operator to confirm. Do not say it was sent.", nil)

  @doc false
  @spec draft_error(term()) :: result()
  def draft_error(:too_many_open_drafts),
    do: result("Five drafts are already waiting for confirmation.", nil, is_error: true)

  def draft_error(:text_too_long),
    do: result("Instruction text must be 4,000 characters or fewer.", nil, is_error: true)

  def draft_error(_reason), do: result("Unable to create a draft.", nil, is_error: true)

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

  defp propose_instruction_spec do
    %{
      name: "propose_instruction",
      description: "Create an instruction draft for the operator to confirm.",
      parameters: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_000}},
        "required" => ["text"],
        "additionalProperties" => false
      }
    }
  end

  defp ask_specs(%Config{agent_channel: nil}, _target), do: []

  defp ask_specs(%Config{agent_channel: channel}, target) do
    case Ports.call_port(channel, :capabilities, [target], :ask) do
      %{ask: true} -> [ask_spec()]
      %{fork: fork} when fork in [:native, :history_copy, :replay] -> [ask_spec()]
      _ -> []
    end
  end

  defp ask_spec do
    %{
      name: "ask_agent",
      description:
        "When the operator asks, question the agent without interrupting its work. Set question_type to history for reasoning or history, and fresh for questions needing new work.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "question" => %{"type" => "string", "minLength" => 1, "maxLength" => 4000},
          "question_type" => %{"type" => "string", "enum" => ["history", "fresh"]}
        },
        "required" => ["question", "question_type"],
        "additionalProperties" => false
      }
    }
  end

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
  defp param(params, "text") when is_map(params), do: Map.get(params, "text", Map.get(params, :text))
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
