defmodule Aiur.RunTelemetry.Lifecycle.BackendOperations do
  @moduledoc "Decodes backend command notifications into build/test lifecycle boundaries for `Aiur.RunTelemetry.Lifecycle`."

  alias Aiur.CodingAgent
  alias Aiur.Protocol.MapAccess
  alias Aiur.RunTelemetry.Lifecycle

  @doc false
  @spec observe_backend_message(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def observe_backend_message(ticket, attempt_id, backend, message, opts)
      when is_binary(ticket) and is_binary(backend) and is_map(message) and is_list(opts) do
    if Lifecycle.enabled?(opts) do
      tracker = Keyword.get(opts, :tracker, self())
      timestamp = MapAccess.message_timestamp(message)

      case backend_operation(backend, message) do
        {:start, operation_id, command} ->
          observe_operation_start(
            ticket,
            attempt_id,
            tracker,
            operation_id,
            command,
            timestamp,
            opts
          )

        {:complete, operation_id, command, outcome} ->
          observe_operation_complete(
            ticket,
            attempt_id,
            tracker,
            operation_id,
            command,
            outcome,
            timestamp,
            opts
          )

        :skip ->
          :ok
      end
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
    _kind, _reason -> :ok
  end

  def observe_backend_message(_ticket, _attempt_id, _backend, _message, _opts), do: :ok

  defp observe_operation_start(
         ticket,
         attempt_id,
         tracker,
         operation_id,
         command,
         timestamp,
         opts
       ) do
    case command_class(command) do
      nil ->
        :ok

      command_class ->
        Process.put(operation_key(tracker, attempt_id, operation_id), command_class)

        Lifecycle.record(
          ticket,
          attempt_id,
          :build_test,
          :start,
          %{operation_id: operation_id, command_class: command_class},
          Keyword.put(opts, :timestamp, timestamp)
        )
    end
  end

  defp observe_operation_complete(
         ticket,
         attempt_id,
         tracker,
         operation_id,
         command,
         outcome,
         timestamp,
         opts
       ) do
    previous_class = Process.delete(operation_key(tracker, attempt_id, operation_id))
    command_class = previous_class || command_class(command)

    if command_class do
      boundary = if previous_class, do: :end, else: :point

      metadata = %{
        operation_id: operation_id,
        command_class: command_class,
        outcome: outcome,
        duration_status: if(boundary == :point, do: :unavailable, else: :measured)
      }

      Lifecycle.record(
        ticket,
        attempt_id,
        :build_test,
        boundary,
        metadata,
        Keyword.put(opts, :timestamp, timestamp)
      )
    end
  end

  defp operation_key(tracker, attempt_id, operation_id),
    do: {Lifecycle, :operation, tracker, attempt_id, operation_id}

  defp backend_operation(backend, message) do
    case get_in(CodingAgent.backends(), [backend, :run_telemetry]) do
      decoder when is_function(decoder, 1) -> decoder.(message)
      _ -> :skip
    end
  end

  @doc false
  @spec decode_codex_operation(map()) ::
          {:start, String.t(), String.t() | nil}
          | {:complete, String.t(), String.t() | nil, atom()}
          | :skip
  def decode_codex_operation(message) do
    method = MapAccess.notification_method(message)
    item = MapAccess.notification_item(message)

    with item when is_map(item) <- item,
         "commandExecution" <- value(item, :type),
         operation_id when not is_nil(operation_id) <- operation_id(item) do
      command = command_from_codex(item)

      case method do
        "item/started" -> {:start, operation_id, command}
        "item/completed" -> {:complete, operation_id, command, codex_outcome(item)}
        _other -> :skip
      end
    else
      _other -> :skip
    end
  end

  @doc false
  @spec decode_claude_operation(map()) ::
          {:start, String.t(), String.t() | nil}
          | {:complete, String.t(), String.t() | nil, atom()}
          | :skip
  def decode_claude_operation(message) do
    with "item/created" <- MapAccess.notification_method(message),
         item when is_map(item) <- MapAccess.notification_item(message) do
      case value(item, :type) do
        "tool_call" ->
          claude_tool_call(item)

        "tool_result" ->
          claude_tool_result(item)

        _other ->
          :skip
      end
    else
      _other -> :skip
    end
  end

  defp claude_tool_call(item) do
    with "Bash" <- value(item, :name),
         operation_id when not is_nil(operation_id) <- operation_id(item) do
      input = value(item, :input) || %{}
      {:start, operation_id, value(input, :command)}
    else
      _other -> :skip
    end
  end

  defp claude_tool_result(item) do
    operation_id =
      value(item, :tool_use_id) || value(item, :tool_call_id) || value(item, :call_id)

    if operation_id do
      {:complete, to_string(operation_id), nil, claude_outcome(item)}
    else
      :skip
    end
  end

  defp operation_id(item) do
    case value(item, :id) || value(item, :item_id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp command_from_codex(item) do
    case value(item, :commandActions) do
      [first | _rest] when is_map(first) -> value(first, :command) || value(item, :command)
      _other -> value(item, :command)
    end
  end

  defp codex_outcome(item) do
    case value(item, :exitCode) do
      0 -> :success
      code when is_integer(code) -> :failed
      _other -> :unknown
    end
  end

  defp claude_outcome(item) do
    case value(item, :is_error) do
      true -> :failed
      false -> :success
      _other -> :unknown
    end
  end

  defp command_class(command) when is_binary(command) do
    command = String.downcase(command)

    cond do
      contains_any?(command, [
        "mix test",
        "make ci",
        "npm test",
        "npm run test",
        "pnpm test",
        "yarn test",
        "pytest",
        "rspec",
        "cargo test",
        "go test",
        "swift test",
        "gradle test",
        "mvn test"
      ]) ->
        :test

      contains_any?(command, [
        "mix compile",
        "mix deps.compile",
        "npm run build",
        "pnpm build",
        "yarn build",
        "cargo build",
        "cargo check",
        "go build",
        "make build",
        "aiurdev build",
        "xcodebuild"
      ]) ->
        :build

      true ->
        nil
    end
  end

  defp command_class(_command), do: nil
  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
