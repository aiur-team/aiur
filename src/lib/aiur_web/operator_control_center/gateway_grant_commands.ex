defmodule AiurWeb.OperatorControlCenter.GatewayGrantCommands do
  @moduledoc """
  Dashboard half of confirming a `gateway_grant` Decision.

  The proof that a human is at this gateway comes from the signed session captured at LiveView mount: a
  Google or passkey sign-in timestamp plus a still-valid dashboard access context. Basic Auth carries neither,
  so it cannot confirm. `Aiur.Gateway.GrantConfirmation` re-checks freshness; this module only translates.
  """

  alias Aiur.Gateway.GrantConfirmation
  alias AiurWeb.FinancialDataAccess

  @spec proof(map()) :: map() | nil
  def proof(session) when is_map(session) do
    with {:ok, _context} <- FinancialDataAccess.context_from_session(session),
         [{at, method, subject} | _] <- sign_ins(session) do
      %{method: method, subject: subject, authenticated_at: at}
    else
      _no_human_sign_in -> nil
    end
  end

  def proof(_session), do: nil

  defp sign_ins(session) do
    [
      {get(session, :google_authenticated_at), :google, get(session, :google_email) || "google"},
      {get(session, :passkey_authenticated_at), :passkey, "passkey"}
    ]
    |> Enum.filter(fn {at, _, _} -> is_integer(at) end)
    |> Enum.sort(:desc)
  end

  defp get(session, key), do: session[key] || session[Atom.to_string(key)]

  @doc "Confirms (or denies) the Decision. Returns `{:notice | :error, text}` for the card."
  @spec confirm(Phoenix.LiveView.Socket.t(), Aiur.Decision.t(), map()) :: {:notice | :error, String.t()}
  def confirm(socket, decision, form) do
    answer = if form["choice"] == "option:approve", do: "approve", else: "deny"

    case GrantConfirmation.confirm(decision.decision_id, answer, socket.assigns[:human_proof] || %{}) do
      {:ok, :approved} -> {:notice, "Granted. The peer can use it now."}
      {:ok, :denied} -> {:notice, "Denied. Nothing changed."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp message(:human_session_required), do: "Sign in with Google or a passkey to confirm. Basic Auth cannot confirm a grant."
  defp message(:session_not_fresh), do: "Your sign-in is older than #{div(GrantConfirmation.fresh_seconds(), 60)} minutes. Sign in again, then confirm."
  defp message(:stale_grant), do: "This grant no longer matches this gateway's registry. Run the grant command again."
  defp message({:write_failed, _reason}), do: "Approved, but the registry file could not be written. Run the grant command again or edit the file by hand."
  defp message(reason), do: "Could not record the answer (#{inspect(reason)})."
end
