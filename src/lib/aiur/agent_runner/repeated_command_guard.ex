defmodule Aiur.AgentRunner.RepeatedCommandGuard do
  @moduledoc """
  Tracks consecutive identical read-only command results within one turn.
  """

  @type state :: %{command: term(), output: term(), count: non_neg_integer()}

  @key {__MODULE__, :turn}

  @doc false
  @spec start_turn(keyword()) :: map()
  def start_turn(opts) when is_list(opts) do
    threshold = Keyword.get(opts, :repeat_threshold, 5)

    Process.put(@key, %{
      threshold: if(is_integer(threshold) and threshold > 0, do: threshold, else: 0),
      state: nil,
      steered?: false,
      commands: 0,
      command_cap: Keyword.get(opts, :command_cap),
      input_token_cap: Keyword.get(opts, :input_token_cap),
      input_tokens: 0,
      usage_epoch: nil,
      usage_baseline: nil,
      pending_commands: %{}
    })
  end

  @doc false
  @spec finish_turn() :: map() | nil
  def finish_turn, do: Process.delete(@key)

  @doc false
  @spec observe_message(map()) :: :ok | {:steer, String.t()}
  def observe_message(message) when is_map(message) do
    steering = observe_command_event(message)
    usage = Map.get(message, :accounting_usage) || Map.get(message, :usage) || Map.get(message, "usage")
    cumulative? = Map.get(message, :usage_source) == :cumulative_only or not is_nil(Map.get(message, :usage_epoch))
    epoch = Map.get(message, :usage_epoch)
    input_tokens = if is_map(usage), do: input_token_count(usage), else: nil

    case {Process.get(@key), input_tokens} do
      {%{input_token_cap: cap} = context, %{input_tokens: amount}}
      when is_integer(cap) and cap > 0 ->
        {current, next} = usage_for_turn(context, amount, epoch, cumulative?)
        Process.put(@key, %{next | input_tokens: current})
        if current > cap, do: throw({:turn_cap, :input_tokens, current})

      _ ->
        :ok
    end

    steering
  end

  def observe_message(_message), do: :ok

  defp observe_command_event(message) do
    case {Process.get(@key), command_event(message)} do
      {%{} = context, {:started, id, command}} ->
        store_pending_command(context, id, command)

      {%{} = context, {:completed, id, output}} ->
        observe_pending_command(context, id, output)

      {%{} = context, {:complete, command, output}} ->
        observe_shell_command(context, command, output)

      _ ->
        :ok
    end
  end

  defp store_pending_command(context, id, command) when is_binary(id) and is_binary(command),
    do: Process.put(@key, put_in(context, [:pending_commands, id], command))

  defp store_pending_command(_context, _id, _command), do: :ok

  defp observe_pending_command(context, id, output) when is_binary(id) and is_binary(output) do
    case Map.pop(context.pending_commands, id) do
      {command, pending} when is_binary(command) ->
        observe_shell_command(%{context | pending_commands: pending}, command, output)

      _ ->
        :ok
    end
  end

  defp observe_pending_command(_context, _id, _output), do: :ok

  defp observe_shell_command(context, command, output) do
    commands = context.commands + 1
    next = %{context | commands: commands}

    {next, signal} =
      if read_only_command?(command) do
        observe_read_result(next, command, output)
      else
        {%{next | state: nil, steered?: false}, :ok}
      end

    Process.put(@key, next)

    if is_integer(context.command_cap) and context.command_cap > 0 and commands >= context.command_cap do
      throw({:turn_cap, :commands, commands})
    end

    signal
  end

  defp observe_read_result(context, command, output) do
    {state, kind} = observe(context.state, command, output)
    next = %{context | state: state, steered?: context.steered? and kind == :repeat}

    cond do
      kind == :repeat and state.count >= context.threshold and context.steered? ->
        throw({:repeated_identical_command, command, state.count})

      kind == :repeat and state.count == context.threshold ->
        {%{next | steered?: true}, {:steer, steering_message(command, state.count)}}

      true ->
        {next, :ok}
    end
  end

  # The provider event path cannot rewrite an already-reported tool result.
  # The caller queues this text as an Executor message for delivery at a safe
  # checkpoint.
  defp command_event(%{event: :notification, payload: payload}) when is_map(payload),
    do: notification_command_event(payload)

  defp command_event(%{event: :tool_call, payload: %{name: "exec_command", arguments: arguments} = payload}),
    do: {:started, payload[:id], get(arguments, :command)}

  defp command_event(%{event: :tool_result, payload: %{name: "exec_command", output: output} = payload}),
    do: {:completed, payload[:id], output}

  defp command_event(_message), do: :none

  defp notification_command_event(payload) do
    method = get(payload, :method)
    item = payload |> get(:params) |> then(&(get(&1 || %{}, :item) || %{}))
    notification_command_event(method, get(item, :type), item)
  end

  defp notification_command_event("item/completed", "commandExecution", item),
    do: {:complete, codex_command(item), get(item, :aggregatedOutput) || ""}

  defp notification_command_event("item/created", "tool_call", item) do
    if get(item, :name) == "Bash",
      do: {:started, get(item, :tool_use_id) || get(item, :id), item |> get(:input) |> then(&get(&1 || %{}, :command))}
  end

  defp notification_command_event("item/created", "tool_result", item),
    do: {:completed, get(item, :tool_use_id) || get(item, :id), normalize_output(get(item, :content))}

  defp notification_command_event(_method, _type, _item), do: :none

  defp codex_command(item) do
    case get(item, :commandActions) do
      [first | _] when is_map(first) -> get(first, :command) || get(item, :command)
      _ -> get(item, :command)
    end
  end

  defp normalize_output(output) when is_binary(output), do: output

  defp normalize_output(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      block when is_map(block) -> get(block, :text) || ""
      _other -> ""
    end)
  end

  defp normalize_output(_output), do: ""

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_map, _key), do: nil

  defp usage_for_turn(context, amount, epoch, true) do
    baseline = if context.usage_epoch == epoch, do: context.usage_baseline, else: amount
    current = max(0, amount - (baseline || amount))
    {current, %{context | usage_epoch: epoch, usage_baseline: baseline}}
  end

  defp usage_for_turn(context, amount, _epoch, false), do: {amount, context}

  defp input_token_count(usage) do
    amount =
      Enum.find_value([:input_tokens, "input_tokens", :prompt_tokens, "prompt_tokens"], fn key ->
        usage |> Map.get(key) |> parse_nonnegative_integer()
      end)

    if is_integer(amount), do: %{input_tokens: amount}
  end

  defp parse_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_nonnegative_integer(_value), do: nil

  @doc "Updates the streak, resetting it whenever the command or output changes."
  @spec observe(state() | nil, term(), term()) :: {state(), :varied | :repeat}
  def observe(nil, command, output), do: {%{command: command, output: output, count: 1}, :varied}

  def observe(%{command: command, output: output, count: count}, command, output),
    do: {%{command: command, output: output, count: count + 1}, :repeat}

  def observe(_state, command, output),
    do: {%{command: command, output: output, count: 1}, :varied}

  @doc "Returns a concise steering instruction with the repeated command and count."
  @spec steering_message(term(), pos_integer()) :: String.t()
  def steering_message(command, count),
    do: "The output of `#{inspect(command)}` has not changed for #{count} consecutive calls; act on it or stop and hand off."

  @read_commands ~w(cat cut file grep head ls pwd stat tail wc)

  defp read_only_command?(command) when is_binary(command) do
    trimmed = String.trim_leading(command)
    first = trimmed |> String.split(~r/\s+/, parts: 2) |> List.first()
    first in @read_commands and not String.match?(trimmed, ~r/[;&|><`$]/)
  end

  defp read_only_command?(_command), do: false
end
