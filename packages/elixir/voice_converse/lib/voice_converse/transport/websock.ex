if Code.ensure_loaded?(WebSockAdapter) and Code.ensure_loaded?(Bandit) do
  defmodule VoiceConverse.Transport.WebSock do
    @moduledoc """
    Standalone, loopback-only-by-default WebSocket transport for a VoiceConverse instance.

    The transport is optional: this module is compiled only when the host includes
    `websock_adapter` and `bandit`. Tokens are verified by the host-provided token issuer with
    the `"converse"` scope; the token itself never becomes session state or a log value.
    """

    alias VoiceConverse.{Events, Ports}

    @max_frame_bytes 400_000
    @token_scope "converse"

    @doc "Starts a standalone Bandit listener. The listener binds IPv4 loopback by default."
    @spec start_link(keyword()) :: Supervisor.on_start()
    def start_link(opts) do
      opts = normalize_options(opts)

      Bandit.start_link(
        scheme: :http,
        plug: {VoiceConverse.Transport.WebSock.Plug, opts},
        ip: Keyword.fetch!(opts, :ip),
        port: Keyword.fetch!(opts, :port),
        startup_log: false
      )
    end

    @doc "A child spec for embedding the standalone listener in a host supervision tree."
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.get(opts, :name, __MODULE__)},
        start: {__MODULE__, :start_link, [opts]},
        type: :worker
      }
    end

    @doc false
    @spec socket_state(keyword(), boolean()) :: map()
    def socket_state(opts, authorized? \\ false) do
      %{
        authorized?: authorized?,
        instance: Keyword.get(opts, :instance, VoiceConverse),
        conversation_id: nil,
        api: Keyword.get(opts, :api, %{})
      }
    end

    @doc false
    @spec authorized?(Elixir.Plug.Conn.t(), keyword()) :: boolean()
    def authorized?(conn, opts) do
      case request_token(conn) do
        nil -> false
        token -> verify_token(token, opts)
      end
    end

    @doc false
    @spec max_frame_bytes() :: pos_integer()
    def max_frame_bytes, do: @max_frame_bytes

    defp normalize_options(opts) do
      opts
      |> Keyword.put_new(:instance, VoiceConverse)
      |> Keyword.put_new(:ip, {127, 0, 0, 1})
      |> Keyword.put_new(:port, 0)
    end

    defp request_token(conn) do
      case Elixir.Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] when byte_size(token) > 0 ->
          token

        [_ | _] ->
          nil

        [] ->
          conn = Elixir.Plug.Conn.fetch_query_params(conn)
          Map.get(conn.query_params, "token")
      end
    end

    defp verify_token(token, opts) do
      with issuer when is_atom(issuer) <- Keyword.get(opts, :token_issuer),
           {:ok, _claims} <-
             Ports.call_port(issuer, :verify, [token, @token_scope, [instance: opts[:instance]]], :token) do
        true
      else
        _ -> false
      end
    end

    defmodule Plug do
      @moduledoc false
      @behaviour Elixir.Plug

      @impl Elixir.Plug
      def init(opts), do: opts

      @impl Elixir.Plug
      def call(%{method: "GET"} = conn, opts) do
        state =
          VoiceConverse.Transport.WebSock.socket_state(opts, VoiceConverse.Transport.WebSock.authorized?(conn, opts))

        # The protocol cap is enforced by Socket so an oversized frame receives the specified
        # `frame_too_large` reply while its WebSocket (and existing session) remain open.
        WebSockAdapter.upgrade(conn, VoiceConverse.Transport.WebSock.Socket, state, [])
      end

      def call(conn, _opts), do: Elixir.Plug.Conn.send_resp(conn, 404, "not found")
    end

    defmodule Socket do
      @moduledoc false
      @behaviour WebSock

      alias VoiceConverse.{Events, Wire}

      @max_frame_bytes 400_000

      @impl WebSock
      def init(%{authorized?: false} = state), do: {:stop, :unauthorized, {4401, "unauthorized"}, state}
      def init(state), do: {:ok, state}

      @impl WebSock
      def handle_in({payload, :text}, state) when byte_size(payload) > @max_frame_bytes,
        do: error(state, "frame_too_large", "Frame exceeds 400000 bytes.")

      def handle_in({payload, :text}, state) do
        with {:ok, frame} <- Wire.decode(payload) do
          dispatch(frame, state)
        else
          {:error, :unsupported_version} -> error(state, "unsupported_version", "Unsupported frame version.")
          {:error, :invalid_frame} -> error(state, "invalid_frame", "Invalid voice frame.")
        end
      end

      def handle_in({_payload, :binary}, state), do: error(state, "invalid_frame", "Frames must be JSON text.")

      @impl WebSock
      def handle_info({:voice_conversation_state, conversation_id, name}, %{conversation_id: conversation_id} = state),
        do: push(%{"v" => 1, "type" => "state", "state" => to_string(name)}, state)

      def handle_info({:voice_conversation, conversation_id, event}, %{conversation_id: conversation_id} = state) do
        case event_frame(event) do
          nil -> {:ok, state}
          frame -> push(frame, state)
        end
      end

      def handle_info(_message, state), do: {:ok, state}

      defp dispatch(%{"type" => "start", "target" => target}, %{conversation_id: nil} = state) do
        case invoke(state, :start_session, [state.instance, target]) do
          {:ok, conversation_id} ->
            case invoke(state, :subscribe, [state.instance, conversation_id, self()]) do
              :ok -> {:ok, %{state | conversation_id: conversation_id}}
              {:error, reason} -> error(state, "session_error", "#{reason}")
            end

          {:error, reason} ->
            error(state, "session_error", "#{reason}")
        end
      end

      defp dispatch(%{"type" => "start"}, state), do: error(state, "session_exists", "A session is already open.")

      defp dispatch(%{"type" => "audio", "data_b64" => audio}, %{conversation_id: conversation_id} = state)
           when is_binary(conversation_id) do
        case invoke(state, :push_audio, [state.instance, conversation_id, audio]) do
          :ok -> {:ok, state}
          {:error, reason} -> error(state, "session_error", "#{reason}")
        end
      end

      defp dispatch(%{"type" => "end"}, %{conversation_id: conversation_id} = state) when is_binary(conversation_id) do
        case invoke(state, :end_session, [state.instance, conversation_id, :user_end]) do
          :ok -> {:ok, state}
          {:error, reason} -> error(state, "session_error", "#{reason}")
        end
      end

      defp dispatch(
             %{"type" => "confirm_draft", "draft_id" => draft_id} = frame,
             %{conversation_id: conversation_id} = state
           )
           when is_binary(conversation_id) do
        edited_text = Map.get(frame, "edited_text")

        case invoke(state, :confirm_draft, [state.conversation_id, draft_id, edited_text]) do
          :ok -> {:ok, state}
          {:error, reason} -> error(state, "draft_error", "#{reason}")
        end
      end

      defp dispatch(%{"type" => "discard_draft", "draft_id" => draft_id}, %{conversation_id: conversation_id} = state)
           when is_binary(conversation_id) do
        case invoke(state, :discard_draft, [state.conversation_id, draft_id]) do
          :ok -> {:ok, state}
          {:error, reason} -> error(state, "draft_error", "#{reason}")
        end
      end

      defp dispatch(%{"type" => "text"}, state), do: error(state, "unsupported_frame", "Text input is unavailable.")
      defp dispatch(_frame, state), do: error(state, "invalid_frame", "Frame is not valid in this direction.")

      defp invoke(%{api: api} = state, operation, args) do
        case Map.fetch(api, operation) do
          {:ok, fun} -> apply(fun, args)
          :error -> default_invoke(state, operation, args)
        end
      end

      defp default_invoke(_state, :start_session, [instance, target]), do: VoiceConverse.start_session(instance, target)

      defp default_invoke(_state, :subscribe, [instance, conversation_id, subscriber]),
        do: VoiceConverse.subscribe(instance, conversation_id, subscriber)

      defp default_invoke(_state, :push_audio, [instance, conversation_id, audio]),
        do: VoiceConverse.push_audio(instance, conversation_id, audio)

      defp default_invoke(_state, :end_session, [instance, conversation_id, reason]),
        do: VoiceConverse.end_session(instance, conversation_id, reason)

      defp default_invoke(_state, :confirm_draft, [conversation_id, draft_id, edited_text]) do
        if function_exported?(VoiceConverse, :confirm_draft, 3) do
          opts = [origin: :client] ++ if(is_nil(edited_text), do: [], else: [edited_text: edited_text])
          apply(VoiceConverse, :confirm_draft, [conversation_id, draft_id, opts])
        else
          {:error, :drafts_unavailable}
        end
      end

      defp default_invoke(_state, :discard_draft, [conversation_id, draft_id]) do
        if function_exported?(VoiceConverse, :discard_draft, 2),
          do: apply(VoiceConverse, :discard_draft, [conversation_id, draft_id]),
          else: {:error, :drafts_unavailable}
      end

      defp event_frame(%Events.UserTranscript{text: text, final?: final?}),
        do: %{"v" => 1, "type" => "transcript", "kind" => if(final?, do: "final", else: "partial"), "text" => text}

      defp event_frame(%Events.AgentText{turn_id: turn_id, text: text, final?: final?}),
        do: %{"v" => 1, "type" => "agent_text", "turn_id" => to_string(turn_id), "text" => text, "final" => final?}

      defp event_frame(%Events.AgentAudio{turn_id: turn_id, format: format, data_b64: data_b64}),
        do: %{
          "v" => 1,
          "type" => "agent_audio",
          "turn_id" => to_string(turn_id),
          "format" => to_string(format),
          "data_b64" => data_b64
        }

      defp event_frame(%Events.Interruption{turn_id: turn_id}),
        do: %{"v" => 1, "type" => "interrupted", "turn_id" => to_string(turn_id)}

      defp event_frame({:error, code, message}),
        do: %{"v" => 1, "type" => "error", "code" => to_string(code), "message" => message}

      defp event_frame({:ended, reason}), do: %{"v" => 1, "type" => "ended", "reason" => to_string(reason)}
      defp event_frame(_event), do: nil

      defp push(frame, state) do
        {:ok, json} = Wire.encode(frame)
        {:push, {:text, json}, state}
      end

      defp error(state, code, message),
        do: push(%{"v" => 1, "type" => "error", "code" => code, "message" => message}, state)
    end
  end
end
