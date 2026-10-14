defmodule Aiur.Opencode.SessionWriter.Parts do
  @moduledoc """
  Part and message row builders for `Aiur.Opencode.SessionWriter`.

  Row JSON shapes stay in `Aiur.Opencode.Protocol`; this module only maps a
  transcript event onto them and inserts the resulting part list.
  """

  alias Aiur.Opencode.{Db, Protocol, SessionWriter}

  @type part :: {String.t(), map()}

  # Returns a list of `{part_id, part_data}` for the event's body. The
  # caller inserts these and (in the live path) fires PATCH events on
  # them.
  @spec build_body_parts(atom(), term(), map()) :: [part()]
  def build_body_parts(:command, body, event) do
    payload = event[:payload] || %{}
    command = Map.get(payload, :command, body)
    output = Map.get(payload, :output, "")
    title = Map.get(payload, :title, body)
    workdir = Map.get(payload, :workdir, "")

    input = %{"command" => command}
    input = if workdir != "", do: Map.put(input, "workdir", workdir), else: input

    part_data =
      Protocol.tool_part_data(
        tool: "bash",
        call_id: Db.call_id(),
        input: input,
        output: output,
        title: title
      )

    [{Db.prt_id(), part_data}]
  end

  def build_body_parts(:tool, body, event) do
    payload = event[:payload] || %{}
    tool = Map.get(payload, :tool, "tool")
    input = Map.get(payload, :input, %{})
    output = Map.get(payload, :output, "")
    title = Map.get(payload, :title, body)

    part_data =
      Protocol.tool_part_data(
        tool: tool,
        call_id: Db.call_id(),
        input: input,
        output: output,
        title: title
      )

    [{Db.prt_id(), part_data}]
  end

  def build_body_parts(:reasoning, body, _event) when is_binary(body) and body != "" do
    [{Db.prt_id(), Protocol.reasoning_part_data(body)}]
  end

  def build_body_parts(_role, body, _event) when is_binary(body) do
    [{Db.prt_id(), Protocol.text_part_data(body)}]
  end

  def build_body_parts(_role, _body, _event), do: []

  @spec insert_part_list(term(), String.t(), String.t(), [part()]) :: :ok | {:error, term()}
  def insert_part_list(conn, session_id, message_id, parts) do
    Enum.reduce_while(parts, :ok, fn {part_id, part_data}, _acc ->
      case Db.insert_part(conn, session_id, message_id, part_id, part_data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec tag_parts(String.t(), [part()]) :: [{String.t(), String.t(), map()}]
  def tag_parts(message_id, parts) do
    Enum.map(parts, fn {part_id, part_data} -> {message_id, part_id, part_data} end)
  end

  @spec build_message_data(SessionWriter.t(), atom()) :: map()
  def build_message_data(state, role) do
    cwd =
      Aiur.Config.workspace_root()
      |> Path.expand()
      |> Aiur.Workspace.workspace_path_under(state.identifier)

    # For turn-grouped messages, opencode renders `finish` from the
    # step-finish part. Set a sensible default on the message row so
    # any reader that consults message JSON alone sees a useful value.
    finish = if role in [:command, :tool], do: "tool-calls", else: "stop"

    Protocol.assistant_message_data(%{
      identifier: state.identifier,
      parent_id: state.root_msg_id || Db.msg_id(),
      cwd: cwd,
      finish: finish
    })
  end
end
