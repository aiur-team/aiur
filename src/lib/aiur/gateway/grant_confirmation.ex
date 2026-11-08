defmodule Aiur.Gateway.GrantConfirmation do
  @moduledoc """
  The only way to answer a `gateway_grant` Decision.

  The Decision store refuses every other answer path for that kind. `confirm/4` needs a proof that a human
  signed in with Google or a passkey on this gateway within `@fresh_seconds`. The proof is verified here,
  not trusted from the web layer. A client token, the Executor, a supervisor or a Basic Auth session
  cannot produce one. On approval the peer's `allows.categories` gains the granted categories.
  """

  alias Aiur.Commands.Answering
  alias Aiur.DecisionStore.HumanConfirmation
  alias Aiur.ControlCall.Audit
  alias Aiur.Gateway.{GrantRequest, Identity, Registry}

  @fresh_seconds 900

  @type error :: :human_session_required | :session_not_fresh | :stale_grant | :not_a_grant | term()

  @spec fresh_seconds() :: pos_integer()
  def fresh_seconds, do: @fresh_seconds

  @spec confirm(String.t(), String.t(), map(), keyword()) :: {:ok, :approved | :denied} | {:error, error()}
  def confirm(decision_id, answer, proof, opts \\ []) when answer in ["approve", "deny"] do
    store = Keyword.get(opts, :store, Aiur.Commands.default_store())
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, proof} <- verify(proof, now),
         {:ok, decision} <- Aiur.DecisionStore.get(decision_id, store),
         {:ok, peer_id, categories} <- current(decision),
         :ok <- answer_decision(decision, answer, proof, store) do
      finish(answer, peer_id, categories, proof)
    end
  end

  defp verify(%{method: method, subject: subject, authenticated_at: at}, now) when method in [:google, :passkey] and is_binary(subject) and is_integer(at) do
    if at <= now and now - at <= @fresh_seconds,
      do: {:ok, %HumanConfirmation{method: method, subject: subject, authenticated_at: at}},
      else: {:error, :session_not_fresh}
  end

  defp verify(_proof, _now), do: {:error, :human_session_required}

  # The digest is re-derived from this gateway's id and the registry as it is now.
  defp current(%{kind: "gateway_grant", decision_status: :open, source_id: source_id}) do
    with {:ok, peer_id, categories, digest} <- GrantRequest.parse(source_id),
         %{gateway_id: gateway_id} when is_binary(gateway_id) <- Identity.current(),
         true <- digest == GrantRequest.digest(peer_id, categories, gateway_id),
         {:ok, %{peers: peers}} <- Registry.get(),
         true <- Enum.any?(Map.values(peers), &(&1.gateway_id == peer_id)) do
      {:ok, peer_id, categories}
    else
      _stale -> {:error, :stale_grant}
    end
  end

  defp current(_decision), do: {:error, :not_a_grant}

  defp answer_decision(decision, answer, proof, store) do
    payload = %{"option_id" => answer, "idempotency_key" => "grant-" <> answer <> "-" <> String.slice(decision.content_hash, 0, 16), "expected_version" => decision.version}
    opts = [actor: %{kind: :operator, id: "dashboard"}, actor_source: :dashboard_session, client: %{surface: :dashboard}, store: store, grant_confirmation: proof]

    case Answering.answer(decision.decision_id, payload, opts) do
      %{status: status} when status in [:accepted, :duplicate] -> :ok
      %{status: :error, reason: reason} -> {:error, reason}
      %{status: status} = outcome -> {:error, Map.get(outcome, :reason, status)}
    end
  end

  defp finish("deny", peer_id, categories, proof) do
    audit("grant_denied", peer_id, categories, proof)
    {:ok, :denied}
  end

  defp finish("approve", peer_id, categories, proof) do
    audit("grant_confirmed", peer_id, categories, proof)

    result =
      Registry.write(
        fn instances ->
          Map.new(instances, fn {name, entry} -> {name, add(entry, peer_id, categories)} end)
        end,
        "dashboard_" <> Atom.to_string(proof.method)
      )

    case result do
      :ok -> {:ok, :approved}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp add(%{"gateway_id" => peer_id} = entry, peer_id, categories) do
    allows = Map.get(entry, "allows") || %{}
    Map.put(entry, "allows", Map.put(allows, "categories", Enum.uniq(Map.get(allows, "categories", ["read"]) ++ categories)))
  end

  defp add(entry, _peer_id, _categories), do: entry

  defp audit(event, peer_id, categories, proof) do
    Audit.append(%{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event,
      actor: "dashboard_" <> Atom.to_string(proof.method),
      method: proof.method,
      subject: proof.subject,
      peer: peer_id,
      categories: categories
    })
  end
end
