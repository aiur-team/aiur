defmodule Aiur.OpenAICompat.CodingAgent do
  @moduledoc """
  Direct OpenAI-compatible coding-agent adapter shared by registered provider
  instances. Provider differences are data in `Aiur.CodingAgent.backends/0`.
  """

  @behaviour Aiur.CodingAgent.Backend

  alias Aiur.OpenAICompat.{AccountGeneration, Config, MeterAdapter, Session, ToolCallParser, Tools, Transport}

  @max_tool_rounds 32

  @impl true
  def start_session(workspace, opts) when is_binary(workspace) and is_list(opts) do
    expanded = Path.expand(workspace)

    with true <- File.dir?(expanded) or {:error, {:invalid_workspace_cwd, expanded}},
         {:ok, config} <- Config.resolve(opts),
         account_generation <-
           AccountGeneration.new_binding(
             config.backend,
             Keyword.get(opts, :account_generation_server, Aiur.ProviderAccountGeneration)
           ),
         {:ok, pid} <-
           Session.start_link(%{
             account_generation: account_generation,
             config: config,
             messages: [],
             next_request_id: 1,
             workspace: expanded
           }) do
      session =
        Map.merge(account_generation, %{
          session_pid: pid,
          thread_id: "openai-compat-#{System.unique_integer([:positive, :monotonic])}",
          workspace: expanded,
          worker_host: Keyword.get(opts, :worker_host),
          resumed: false
        })

      :ok = AccountGeneration.bind(session)
      {:ok, session}
    end
  end

  @impl true
  def run_turn(%{session_pid: pid} = session, prompt, _issue, opts)
      when is_pid(pid) and is_binary(prompt) and is_list(opts) do
    if Process.alive?(pid) do
      state = Session.get(pid)
      state = %{state | messages: state.messages ++ [%{"role" => "user", "content" => prompt}]}

      state |> run_loop(opts, 0) |> commit_turn(pid, session)
    else
      {:error, :session_closed}
    end
  end

  def run_turn(_session, _prompt, _issue, _opts), do: {:error, :invalid_session}

  defp commit_turn({:ok, state, completion}, pid, session) do
    Session.update(pid, fn _ -> state end)
    {:ok, Map.merge(session, %{result: :turn_completed, completion: completion})}
  end

  defp commit_turn({:paused, state, payload}, pid, session) do
    Session.update(pid, fn _ -> state end)
    {:paused, Map.put(payload, :session_id, session.thread_id)}
  end

  defp commit_turn({:error, state, reason}, pid, _session) do
    Session.update(pid, fn _ -> state end)
    {:error, reason}
  end

  @impl true
  def stop_session(%{session_pid: pid}) when is_pid(pid) do
    state = if Process.alive?(pid), do: Session.get(pid), else: %{}
    :ok = AccountGeneration.process_stopped(Map.get(state, :account_generation, %{}))
    :ok = Session.stop(pid)
    {:ok, :cleanup_proven}
  end

  def stop_session(_session), do: {:ok, :cleanup_proven}

  @impl true
  def normalize_event(event) when is_map(event) do
    event
    |> Map.put_new(:timestamp, DateTime.utc_now())
    |> Map.update(:raw, nil, &redact_raw/1)
  end

  @impl true
  def send_operator_message(%{session_pid: pid}, %{kind: :text, body: text})
      when is_pid(pid) and is_binary(text) do
    Agent.get_and_update(pid, fn state ->
      request_id = state.next_request_id
      next = %{state | next_request_id: request_id + 1, messages: state.messages ++ [%{"role" => "user", "content" => text}]}
      {{:ok, request_id}, next}
    end)
  catch
    :exit, _ -> {:error, :session_closed}
  end

  def send_operator_message(_session, _payload), do: {:error, :unsupported_payload}

  defp run_loop(state, _opts, rounds) when rounds >= @max_tool_rounds,
    do: {:error, state, :tool_round_limit_exceeded}

  defp run_loop(state, opts, rounds) do
    with :continue <- pause_state(),
         {:ok, completion} <- Transport.complete(state.config, state.messages, Tools.specs(state.config.transport)) do
      completion = maybe_parse_text_tool_calls(completion, state.config)
      MeterAdapter.observe(completion, state, opts)
      emit_completion(completion, state, opts)
      state = append_assistant(state, completion)

      case completion.tool_calls do
        [] -> finish_or_continue(state, completion, opts, rounds)
        calls -> run_tool_round(state, calls, opts, rounds)
      end
    else
      {:paused, payload} -> {:paused, state, payload}
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp finish_or_continue(state, completion, opts, rounds) do
    case deliver_checkpoint(state, %{kind: :notification, method: "response/completed"}, opts) do
      {:delivered, state} ->
        run_loop(state, opts, rounds + 1)

      {:noop, state} ->
        emit(opts, %{event: :turn_completed, payload: %{id: completion.id}})
        {:ok, state, completion}
    end
  end

  defp run_tool_round(state, calls, opts, rounds) do
    case execute_tools(state, calls, opts) do
      {:ok, next} ->
        # A pause landing between the last tool result and here must keep the
        # state the tool results were appended to, or the round is replayed.
        case pause_state() do
          :continue -> run_loop(next, opts, rounds + 1)
          {:paused, payload} -> {:paused, next, payload}
        end

      {:paused, current, payload} ->
        {:paused, current, payload}

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp execute_tools(state, calls, opts) do
    Enum.reduce_while(calls, {:ok, state}, fn call, {:ok, current} ->
      emit(opts, %{event: :tool_call, payload: %{id: call.id, name: call.name, arguments: display_arguments(call.arguments)}})

      result =
        case Tools.decode_and_validate(call.name, call.arguments) do
          {:ok, arguments} ->
            Tools.execute(
              call.name,
              arguments,
              %{workspace: current.workspace, tool_executor: Keyword.get(opts, :tool_executor)},
              opts
            )

          {:error, reason} ->
            %{"success" => false, "output" => "invalid arguments: #{reason}"}
        end

      output = stringify_output(result["output"])
      success = result["success"] == true

      emit(opts, %{event: :tool_result, payload: %{id: call.id, name: call.name, output: output, success: success}})

      current =
        current
        |> append_tool_result(call, output)

      {_delivery, current} = deliver_checkpoint(current, %{kind: :tool_result, method: "tool/result"}, opts)

      case pause_state() do
        :continue -> {:cont, {:ok, current}}
        {:paused, payload} -> {:halt, {:paused, current, payload}}
      end
    end)
  end

  defp append_assistant(%{config: %{transport: :responses}} = state, %{output: output})
       when is_list(output) do
    %{state | messages: state.messages ++ output}
  end

  defp append_assistant(state, completion) do
    message =
      completion.message
      |> Map.put("role", "assistant")
      |> maybe_put_reasoning(completion, state.config)
      |> maybe_put_tool_calls(completion.tool_calls)

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

  defp append_tool_result(state, call, output) do
    message =
      case state.config.transport do
        :responses -> %{"type" => "function_call_output", "call_id" => call.id, "output" => output}
        :chat_completions -> %{"role" => "tool", "tool_call_id" => call.id, "content" => output}
      end

    %{state | messages: state.messages ++ [message]}
  end

  defp deliver_checkpoint(state, checkpoint, opts) do
    callback = Keyword.get(opts, :on_safe_checkpoint, fn _ -> :noop end)

    case callback.(checkpoint) do
      :noop ->
        {:noop, state}

      {:deliver_text, text, on_success, _on_failure}
      when is_binary(text) and is_function(on_success, 1) ->
        request_id = state.next_request_id

        on_success.(%{
          backend: state.config.backend,
          checkpoint: checkpoint.kind,
          request_id: request_id,
          turn_id: "openai-compat-#{request_id}"
        })

        {:delivered,
         %{
           state
           | next_request_id: request_id + 1,
             messages: state.messages ++ [%{"role" => "user", "content" => text}]
         }}

      {:deliver_text, _text, _on_success, on_failure} when is_function(on_failure, 1) ->
        on_failure.(:invalid_operator_message)
        {:noop, state}

      _ ->
        {:noop, state}
    end
  rescue
    error ->
      case Keyword.get(opts, :on_checkpoint_error) do
        fun when is_function(fun, 1) -> fun.(error)
        _ -> :ok
      end

      {:noop, state}
  end

  defp emit_completion(completion, state, opts) do
    if is_binary(completion.reasoning) and completion.reasoning != "" do
      emit(opts, %{event: :reasoning, payload: %{id: completion.id, text: completion.reasoning}})
    end

    if is_binary(completion.text) and completion.text != "" do
      emit(opts, %{event: :assistant, payload: %{id: completion.id, text: completion.text}})
    end

    if is_map(completion.usage) do
      account_generation = AccountGeneration.snapshot(state.account_generation)

      emit(opts, %{
        event: :usage,
        request_id: completion.id,
        model: completion.model,
        provider: completion.provider,
        account_generation: account_generation,
        usage: completion.usage,
        payload: %{
          "usage" => completion.usage,
          "request_id" => completion.id,
          "model" => completion.model,
          "provider" => completion.provider
        }
      })
    end
  end

  defp emit(opts, event) do
    event = normalize_event(event)
    Keyword.get(opts, :on_message, fn _ -> :ok end).(event)
  end

  defp maybe_parse_text_tool_calls(%{tool_calls: []} = completion, %{quirks: %{text_tool_fallback: true}}) do
    case ToolCallParser.parse(completion.text) do
      [] -> completion
      calls -> %{completion | tool_calls: calls}
    end
  end

  defp maybe_parse_text_tool_calls(completion, _config), do: completion

  defp pause_state do
    receive do
      {:pause_agent, request_id} -> {:paused, %{reason: :operator_pause, request_id: request_id}}
      {:pause_agent, request_id, generation} -> {:paused, %{reason: :operator_pause, request_id: request_id, generation: generation}}
      {:agent_queue_updated, _identifier, _item_id, _deliver_now?} -> pause_state()
      {:agent_queue_updated, _identifier, _item_id} -> pause_state()
    after
      0 -> :continue
    end
  end

  defp display_arguments(arguments) when is_map(arguments), do: arguments

  defp display_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp display_arguments(_), do: %{}

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp encode_arguments(_), do: "{}"

  defp stringify_output(output) when is_binary(output), do: output
  defp stringify_output(output), do: Jason.encode!(output)

  defp redact_raw(raw) when is_binary(raw), do: Aiur.SecretRedactor.redact(raw)
  defp redact_raw(_), do: nil
end
