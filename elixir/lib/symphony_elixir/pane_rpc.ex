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

  alias SymphonyElixir.{AgentChat, AgentDirectory, AgentEvents, IssueContext, IssueLog}

  @max_body_bytes 65_536

  @spec snapshot() :: [AgentEvents.agent_summary()]
  def snapshot, do: AgentDirectory.list_agents()

  @spec send_operator_message(AgentEvents.agent_identifier(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def send_operator_message(identifier, body)
      when is_binary(identifier) and is_binary(body) do
    # Pane submits use `:checkpoint` delivery — the message lands at
    # the next safe codex boundary (notification or tool result)
    # instead of cancelling the in-flight tool. Long-running tools
    # like `sleep 300` are no longer killed by a typed message; they
    # complete first, then the operator message is delivered.
    #
    # `:queue_next` fallback means a non-interrupt-capable agent still
    # queues the message instead of erroring. Other consumers of
    # `AgentChat.send` (web UI, automation) keep their own defaults.
    with {:ok, sanitized} <- validate_body(body) do
      AgentChat.send(identifier, sanitized,
        delivery_policy: :checkpoint,
        fallback: :queue_next
      )
    end
  end

  @spec attach_conversation(AgentEvents.agent_identifier()) :: :ok | {:error, term()}
  def attach_conversation(identifier) when is_binary(identifier),
    do: attach_conversation(identifier, SymphonyElixir.Conversations)

  @doc false
  @spec attach_conversation(AgentEvents.agent_identifier(), module()) :: :ok | {:error, term()}
  def attach_conversation(identifier, conversations)
      when is_binary(identifier) and is_atom(conversations) do
    case conversations.attach(identifier) do
      {:ok, _ref} -> :ok
      error -> error
    end
  end

  @doc """
  Fetches the per-issue intro context plus any recent transcript/alert
  history captured by `SymphonyElixir.IssueLog`. The pane calls this
  during `init/1` so the operator sees what the agent is working on
  immediately, even when the agent is mid-turn and not producing output.

  Returns a map shaped for the conversation pane's
  `prepend_pane_intro/2`: a `:context_message` body (or `nil` if no
  detail is available) and a `:history` list of past events oldest-first.
  """
  @spec fetch_context(AgentEvents.agent_identifier(), pos_integer()) ::
          {:ok, %{context_message: String.t() | nil, history: [tuple()]}}
  def fetch_context(identifier, limit \\ 50) when is_binary(identifier) do
    summary = IssueContext.for(identifier)
    history = IssueLog.history(identifier, limit)

    context_message =
      case summary do
        %{title: nil, description: nil, url: nil} -> nil
        _ -> IssueContext.to_message(summary)
      end

    {:ok, %{context_message: context_message, history: history}}
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
