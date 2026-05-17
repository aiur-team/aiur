defmodule SymphonyElixir.PaneRPC do
  @moduledoc """
  Explicit chokepoint for cross-node calls from pane subcommands.

  Pane BEAM nodes invoke only the functions in this module via `:rpc.call/4`
  (or `:rpc.cast/4`). Per the security review, this is a documentation /
  audit-logging convention rather than a hard distribution boundary
  (Erlang distribution does not enforce per-call allowlists). When future
  features lower the trust level for pane code, this module becomes the
  single place to add enforcement.

  Server-side input validation (length cap, control-char filter, RPC
  timeouts) lives here, not at every internal hop.

  Scaffold: implementations land alongside the conversation pane subcommand.
  """

  alias SymphonyElixir.{AgentChat, AgentDirectory, AgentEvents}

  @max_body_bytes 65_536

  @spec snapshot() :: [AgentEvents.agent_summary()]
  def snapshot, do: AgentDirectory.list_agents()

  @spec send_operator_message(AgentEvents.agent_identifier(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def send_operator_message(identifier, body)
      when is_binary(identifier) and is_binary(body) do
    with {:ok, sanitized} <- validate_body(body) do
      AgentChat.send(identifier, sanitized)
    end
  end

  @spec attach_conversation(AgentEvents.agent_identifier()) :: :ok | {:error, term()}
  def attach_conversation(identifier) when is_binary(identifier) do
    case SymphonyElixir.Conversations.attach(identifier) do
      {:ok, _ref} -> :ok
      error -> error
    end
  end

  @spec detach_conversation(AgentEvents.agent_identifier()) :: :ok
  def detach_conversation(identifier) when is_binary(identifier) do
    SymphonyElixir.Conversations.detach(%{identifier: identifier, pid: self()})
  end

  defp validate_body(body) when byte_size(body) > @max_body_bytes, do: {:error, :body_too_long}

  defp validate_body(body) do
    {:ok, String.replace(body, ~r/[\x00-\x08\x0B-\x1F]/, "")}
  end
end
