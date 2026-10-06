defmodule Aiur.Muse.Protocol do
  @moduledoc """
  Pure builders and typed result readers for Muse's JSON-RPC MSP wire.

  A command receipt only confirms admission. A turn reaches an outcome through
  a matching `turn/completed` notification.
  """

  @type request_id :: integer() | String.t()
  @type frame :: map()

  @spec command_id() :: String.t()
  def command_id do
    <<random_a::12, random_b::62, _::6>> = :crypto.strong_rand_bytes(10)
    timestamp = System.system_time(:millisecond)
    bytes = <<timestamp::48, 7::4, random_a::12, 2::2, random_b::62>>

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> =
      Base.encode16(bytes, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  @spec initialize_frame(request_id(), String.t()) :: frame()
  def initialize_frame(id, version) do
    request(id, "initialize", %{
      "clientInfo" => %{"name" => "aiur", "version" => version},
      "capabilities" => %{
        "requestedCapabilities" => ["sessionMcp"],
        "userInputDialogs" => false
      }
    })
  end

  @spec initialized_frame() :: frame()
  def initialized_frame, do: %{"jsonrpc" => "2.0", "method" => "initialized"}

  @spec session_start_frame(request_id(), Path.t(), keyword()) :: frame()
  def session_start_frame(id, workspace, opts \\ []) do
    params = %{"commandId" => Keyword.get_lazy(opts, :command_id, &command_id/0), "workspaceRoot" => workspace}
    request(id, "session/start", with_options(params, opts, %{config: "config", model_id: "modelId", provider_id: "providerId", approval_mode: "approvalMode", session_id: "sessionId"}))
  end

  @spec session_resume_frame(request_id(), String.t(), keyword()) :: frame()
  def session_resume_frame(id, session_id, opts \\ []) do
    params = %{"commandId" => Keyword.get_lazy(opts, :command_id, &command_id/0), "sessionId" => session_id}
    request(id, "session/resume", with_options(params, opts, %{config: "config", cursor: "cursor", history: "history", exclude_items: "excludeItems"}))
  end

  @spec turn_start_frame(request_id(), String.t(), String.t(), keyword()) :: frame()
  def turn_start_frame(id, session_id, prompt, opts \\ []) when is_binary(prompt) and byte_size(prompt) > 0 do
    params = %{
      "commandId" => Keyword.get_lazy(opts, :command_id, &command_id/0),
      "sessionId" => session_id,
      "input" => [%{"type" => "text", "text" => prompt}]
    }

    request(id, "turn/start", with_options(params, opts, %{display_text: "displayText", if_busy: "ifBusy", reasoning_effort: "reasoningEffort"}))
  end

  @spec turn_interrupt_frame(request_id(), String.t(), String.t() | nil, keyword()) :: frame()
  def turn_interrupt_frame(id, session_id, turn_id \\ nil, opts \\ []) do
    params = %{"commandId" => Keyword.get_lazy(opts, :command_id, &command_id/0), "sessionId" => session_id}
    params = if is_nil(turn_id), do: params, else: Map.put(params, "turnId", turn_id)
    request(id, "turn/interrupt", with_options(params, opts, %{retract: "retract"}))
  end

  @spec initialize_result(map()) :: {:ok, map()} | {:error, term()}
  def initialize_result(%{"grantedCapabilities" => grants, "schema" => %{"version" => version}} = result)
      when is_list(grants) and is_integer(version) do
    cond do
      version != 1 -> {:error, {:unsupported_schema_version, version}}
      "sessionMcp" not in grants -> {:error, :session_mcp_not_granted}
      true -> {:ok, result}
    end
  end

  def initialize_result(_), do: {:error, :invalid_initialize_result}

  @spec session_result(map()) :: {:ok, map()} | {:error, term()}
  def session_result(%{"session" => %{"sessionId" => session_id}, "viewCursor" => cursor} = result)
      when is_binary(session_id) and is_binary(cursor), do: {:ok, result}

  def session_result(_), do: {:error, :invalid_session_result}

  @spec turn_start_result(map(), String.t()) :: {:accepted, map()} | {:error, term()}
  def turn_start_result(%{"commandId" => command_id, "status" => "accepted", "turnId" => turn_id, "disposition" => disposition, "startedNewTurn" => started?} = result, command_id)
      when is_binary(turn_id) and disposition in ["started", "queued", "steered"] and is_boolean(started?),
      do: {:accepted, result}

  def turn_start_result(_, _), do: {:error, :invalid_turn_start_receipt}

  @spec turn_interrupt_result(map(), String.t()) :: {:accepted, map()} | {:error, term()}
  def turn_interrupt_result(%{"commandId" => command_id, "status" => "accepted", "turnId" => turn_id} = result, command_id)
      when is_binary(turn_id), do: {:accepted, result}

  def turn_interrupt_result(_, _), do: {:error, :invalid_turn_interrupt_receipt}

  @spec turn_completed(map(), String.t(), String.t()) :: {:terminal, atom(), map()} | {:error, term()}
  def turn_completed(%{"method" => "turn/completed", "params" => params}, session_id, turn_id)
      when is_map(params) do
    case params do
      %{"sessionId" => ^session_id, "turnId" => ^turn_id, "terminal" => terminal, "viewCursor" => cursor, "sourceRange" => source_range}
      when terminal in ["completed", "failed", "cancelled"] and is_binary(cursor) and is_map(source_range) ->
        classify_terminal(terminal, params)

      _ ->
        {:error, :invalid_turn_completion}
    end
  end

  def turn_completed(_, _, _), do: {:error, :invalid_turn_completion}

  defp classify_terminal("failed", %{"error" => %{"kind" => kind, "message" => message, "retryable" => retryable}} = params)
       when is_binary(kind) and is_binary(message) and is_boolean(retryable), do: {:terminal, :failed, params}

  defp classify_terminal("failed", _), do: {:error, :missing_turn_error}
  defp classify_terminal("completed", params), do: {:terminal, :completed, params}
  defp classify_terminal("cancelled", params), do: {:terminal, :cancelled, params}

  defp request(id, method, params), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp with_options(params, opts, names) do
    Enum.reduce(names, params, fn {key, wire_name}, acc ->
      if Keyword.has_key?(opts, key), do: Map.put(acc, wire_name, Keyword.fetch!(opts, key)), else: acc
    end)
  end
end
