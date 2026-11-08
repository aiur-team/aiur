defmodule Aiur.Gateway.GrantRequest do
  @moduledoc """
  Raises the human-required `gateway_grant` Decision for a pending write grant.

  The pending grant is the open Decision; the registry file changes only when a signed-in human approves
  (`Aiur.Gateway.GrantConfirmation`). The Decision's `source_id` carries the peer, categories and a digest
  bound to this gateway's id, so repeating the command returns the same Decision and a Decision raised on
  another gateway can never match.
  """

  alias Aiur.Commands

  @prefix "gateway_grant:"
  @verbs %{
    "read" => "read status",
    "message" => "send messages",
    "executor" => "control the Executor",
    "agents" => "pause, resume and steer agents",
    "tickets" => "change tickets",
    "config" => "change configuration"
  }

  @spec request(map(), [String.t()], keyword()) :: {:ok, Aiur.Decision.t()} | {:error, term()}
  def request(peer, categories, opts \\ []) do
    categories = Enum.sort(categories)

    with %{gateway_id: gateway_id} when is_binary(gateway_id) <- Aiur.Gateway.Identity.current() do
      source_id = source_id(peer.gateway_id, categories, gateway_id)
      store = Keyword.get(opts, :store, Commands.default_store())

      case Commands.request(payload(peer, categories, gateway_id, source_id), request_opts(source_id), store) do
        {:ok, %{decision: decision}} -> {:ok, decision}
        {:error, _reason} = error -> error
      end
    else
      _unavailable -> {:error, :gateway_identity_unavailable}
    end
  catch
    :exit, _reason -> {:error, :daemon_unavailable}
  end

  @doc "`gateway_grant:<peer id>:<categories joined by +>:<digest>`; the digest binds it to this gateway."
  @spec source_id(String.t(), [String.t()], String.t()) :: String.t()
  def source_id(peer_id, categories, gateway_id), do: @prefix <> peer_id <> ":" <> Enum.join(Enum.sort(categories), "+") <> ":" <> digest(peer_id, categories, gateway_id)

  @spec digest(String.t(), [String.t()], String.t()) :: String.t()
  def digest(peer_id, categories, gateway_id) do
    :crypto.hash(:sha256, Enum.join([peer_id, Enum.join(Enum.sort(categories), ","), gateway_id], "|")) |> Base.encode16(case: :lower)
  end

  @spec parse(String.t() | nil) :: {:ok, String.t(), [String.t()], String.t()} | :error
  def parse(@prefix <> rest) do
    case String.split(rest, ":") do
      [peer_id, categories, digest] -> {:ok, peer_id, String.split(categories, "+"), digest}
      _other -> :error
    end
  end

  def parse(_source_id), do: :error

  defp payload(peer, categories, gateway_id, source_id) do
    label = peer.label || peer.name
    what = categories |> Enum.map(&Map.get(@verbs, &1, &1)) |> Enum.join(", ")

    %{
      kind: "gateway_grant",
      source_id: source_id,
      question: "Let #{label} (gateway #{String.slice(peer.gateway_id, 0, 8)}) #{Enum.join(categories, ", ")} on this gateway?",
      options: [%{id: "approve", label: "Grant #{Enum.join(categories, ", ")}"}, %{id: "deny", label: "Deny"}],
      recommendation: %{option_id: "deny", reason: "Grant only what you expect this peer to need; you can revoke it later."},
      authority: :human_required,
      reversibility: :reversible,
      blocking: false,
      urgency: "normal",
      context: %{
        short_summary: "#{label} will be able to #{what} on this gateway until you revoke it.",
        long_context_markdown: "Gateway `#{String.slice(gateway_id, 0, 8)}` grants write categories only after a human signed in with Google or a passkey confirms here.",
        authority_basis: "security"
      }
    }
  end

  defp request_opts(source_id) do
    [
      ticket: %{identifier: "executor"},
      source: %{agent_id: "executor", session_id: "gateway-grant", event_id: source_id},
      requester: %{kind: :executor, executor_id: "gateway-grant"},
      origin: :executor_cli
    ]
  end
end
