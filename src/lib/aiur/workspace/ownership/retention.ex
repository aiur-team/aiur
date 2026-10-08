defmodule Aiur.Workspace.Ownership.Retention do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.Workspace.Ownership

  @spec mark(map(), String.t() | nil) :: map()
  def mark(state, cause \\ nil)
  def mark(%{lease: %{retained_since: since}} = state, nil) when is_binary(since), do: state

  def mark(%{lease: %{retained_since: since}} = state, cause) when is_binary(since) do
    {lease, _} = Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :retained_cause, cause))
    %{state | lease: lease}
  end

  def mark(state, cause) do
    since = DateTime.utc_now() |> DateTime.to_iso8601()
    cause = cause || if state.provider_scope == :remote or match?(%{remote: true}, state.provider), do: "remote_provider_exit_unproven", else: "provider_unrecorded"
    {lease, _} = Registry.update_value(state.registry, state.lease.ticket, &Map.merge(&1, %{retained_since: since, retained_cause: cause}))
    message = "Workspace retained for #{lease.ticket} (generation #{lease.generation}) since #{since}: #{cause}."

    Alerts.emit_system("ticket.#{lease.ticket}.workspace.workspace_lease_retained",
      issue: lease.ticket,
      message: message,
      reason: message,
      needs_attention: true,
      severity: "warning",
      exchange_payload: %{"identifier" => lease.ticket, "generation" => lease.generation, "provider" => state.provider, "since" => since}
    )

    %{state | lease: lease}
  end

  @spec resolve(map()) :: :ok | {:error, term()}
  def resolve(%{retained_since: since} = lease) when is_binary(since) do
    message = "Workspace retained lease released for #{lease.ticket} (generation #{lease.generation})."
    Alerts.emit_system("ticket.#{lease.ticket}.workspace.workspace_lease_retained.resolved", issue: lease.ticket, message: message, reason: message, needs_attention: false)
  end

  def resolve(_lease), do: :ok

  @spec for_ticket(String.t(), Ownership.registry()) :: map() | nil
  def for_ticket(ticket, registry \\ Aiur.Workspace.Ownership.Registry) do
    case Ownership.current(ticket, registry) do
      {:ok, %{phase: :reaping, retained_since: since} = lease} when is_binary(since) ->
        %{since: since, cause: lease[:retained_cause], generation: lease.generation}

      _ ->
        nil
    end
  end
end
