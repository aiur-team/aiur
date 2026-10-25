defmodule Aiur.Workspace.Ownership.Retention do
  @moduledoc false

  alias Aiur.Signal
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Guardian.Receipt

  @spec mark(map(), String.t() | nil) :: map()
  def mark(state, cause \\ nil)

  def mark(%{lease: %{retained_cause: cause}} = state, nil) when is_binary(cause),
    do: Receipt.update_phase(state, :reaping)

  def mark(%{lease: %{retained_cause: previous}} = state, cause) when is_binary(previous) do
    {lease, _} = Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :retained_cause, cause))
    Receipt.update_phase(%{state | lease: lease}, :reaping)
  end

  def mark(state, cause) do
    since = Map.get(state.lease, :retained_since, DateTime.utc_now() |> DateTime.to_iso8601())
    cause = cause || if state.provider_scope == :remote or match?(%{remote: true}, state.provider), do: "remote_provider_exit_unproven", else: "provider_unrecorded"
    {lease, _} = Registry.update_value(state.registry, state.lease.ticket, &Map.merge(&1, %{retained_since: since, retained_cause: cause}))
    state = Receipt.update_phase(%{state | lease: lease}, :reaping)
    message = "Workspace retained for #{lease.ticket} (generation #{lease.generation}) since #{since || "unknown"}: #{cause}."

    state.retention_alert_fun.("ticket.#{lease.ticket}.workspace.workspace_lease_retained",
      issue: lease.ticket,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning",
      exchange_payload: %{"identifier" => lease.ticket, "generation" => lease.generation, "provider" => state.provider, "since" => since}
    )

    state
  end

  @spec resolve(map()) :: :ok | {:error, term()}
  def resolve(%{retained_cause: cause} = lease) when is_binary(cause) do
    message = "Workspace retained lease released for #{lease.ticket} (generation #{lease.generation})."
    Signal.alert("ticket.#{lease.ticket}.workspace.workspace_lease_retained.resolved", issue: lease.ticket, message: message, reason: message, needs_attention: false)
  end

  def resolve(_lease), do: :ok

  @spec for_ticket(String.t(), Ownership.registry()) :: map() | nil
  def for_ticket(ticket, registry \\ Aiur.Workspace.Ownership.Registry) do
    case Ownership.current(ticket, registry) do
      {:ok, %{phase: :reaping, retained_cause: cause} = lease} when is_binary(cause) ->
        %{since: lease[:retained_since], cause: cause, generation: lease.generation}

      _ ->
        nil
    end
  end
end
