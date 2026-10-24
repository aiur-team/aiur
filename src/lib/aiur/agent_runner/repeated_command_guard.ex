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
      usage_baseline: nil
    })
  end

  @doc false
  @spec finish_turn() :: map() | nil
  def finish_turn, do: Process.delete(@key)

  @doc false
  @spec observe_tool(term(), term(), term()) :: term()
  def observe_tool(tool, arguments, result) do
    case Process.get(@key) do
      nil ->
        result

      context ->
        commands = context.commands + 1
        next = %{context | commands: commands}
        result = observe_active_tool(next, tool, arguments, result)
        enforce_command_cap(next, result)
    end
  end

  @doc false
  @spec before_tool() :: :ok
  def before_tool, do: :ok

  @doc false
  @spec observe_message(map()) :: :ok
  def observe_message(message) when is_map(message) do
    usage = Map.get(message, :accounting_usage) || Map.get(message, :usage) || Map.get(message, "usage")
    cumulative? = Map.get(message, :usage_source) == :cumulative_only or not is_nil(Map.get(message, :usage_epoch))
    epoch = Map.get(message, :usage_epoch)
    input_tokens = if is_map(usage), do: Aiur.TokenUsage.canonicalize(usage), else: nil

    case {Process.get(@key), input_tokens} do
      {%{input_token_cap: cap} = context, %{input_tokens: amount}}
      when is_integer(cap) and cap > 0 ->
        {current, next} = usage_for_turn(context, amount, epoch, cumulative?)
        Process.put(@key, %{next | input_tokens: current})
        if current > cap, do: throw({:turn_cap, :input_tokens, current})

      _ ->
        :ok
    end

    :ok
  end

  def observe_message(_message), do: :ok

  defp usage_for_turn(context, amount, epoch, true) do
    baseline = if context.usage_epoch == epoch, do: context.usage_baseline, else: amount
    current = max(0, amount - (baseline || amount))
    {current, %{context | usage_epoch: epoch, usage_baseline: baseline}}
  end

  defp usage_for_turn(context, amount, _epoch, false), do: {amount, context}

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

  defp observe_active_tool(context, tool, arguments, result) do
    command = read_command(tool, arguments)
    output = result_output(result)

    case {command, output} do
      {command, output} when is_binary(command) and is_binary(output) ->
        apply_observation(context, command, output, result)

      _ ->
        Process.put(@key, %{context | state: nil, steered?: false})

        result
    end
  end

  defp apply_observation(context, command, output, result) do
    {state, kind} = observe(context.state, command, output)
    next = %{context | state: state, steered?: context.steered? and kind == :repeat}

    handle_observation(context, next, command, state, kind, result)
  end

  defp handle_observation(context, _next, command, state, :repeat, _result)
       when state.count >= context.threshold and context.steered? do
    throw({:repeated_identical_command, command, state.count})
  end

  defp handle_observation(context, next, command, state, :repeat, result)
       when state.count == context.threshold do
    Process.put(@key, %{next | steered?: true})
    append_guidance(result, steering_message(command, state.count))
  end

  defp handle_observation(_context, next, _command, _state, _kind, result) do
    Process.put(@key, next)
    result
  end

  defp enforce_command_cap(context, result) do
    if is_integer(context.command_cap) and context.command_cap > 0 and
         context.commands >= context.command_cap do
      throw({:turn_cap, :commands, context.commands})
    end

    result
  end

  @read_commands ~w(cat cut file grep head ls pwd stat tail wc)

  defp read_command(tool, arguments)
       when tool in ["exec_command", "Bash", "bash"] and is_map(arguments) do
    command = Map.get(arguments, "command") || Map.get(arguments, :command)

    if read_only_command?(command), do: command
  end

  defp read_command(_tool, _arguments), do: nil

  defp read_only_command?(command) when is_binary(command) do
    trimmed = String.trim_leading(command)
    first = trimmed |> String.split(~r/\s+/, parts: 2) |> List.first()
    first in @read_commands and not String.match?(trimmed, ~r/[;&|><`$]/)
  end

  defp read_only_command?(_command), do: false

  defp result_output(%{"output" => output}) when is_binary(output), do: output
  defp result_output(%{output: output}) when is_binary(output), do: output
  defp result_output(_result), do: nil

  defp append_guidance(%{"output" => output} = result, guidance),
    do: Map.put(result, "output", output <> "\n\n" <> guidance)

  defp append_guidance(%{output: output} = result, guidance),
    do: Map.put(result, :output, output <> "\n\n" <> guidance)

  defp append_guidance(result, _guidance), do: result
end
