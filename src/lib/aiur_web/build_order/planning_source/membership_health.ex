defmodule AiurWeb.BuildOrder.PlanningSource.MembershipHealth do
  @moduledoc "Provider, membership and pack-status health projections for the planning source."

  import AiurWeb.BuildOrder.PlanningSource.PackLoader, only: [status_lifecycle: 2, ticket_identity: 2]

  alias Aiur.BuildOrder.{PackStatus, ProviderHealth}

  @generation 1

  @doc false
  @spec provider(term(), [map()]) :: {ProviderHealth.t(), ProviderHealth.t() | nil, term()}
  def provider(membership, packs) do
    pack_status_snapshot = pack_status_health_snapshot()
    status_health = pack_status_health(packs, pack_status_snapshot)
    source_generation = source_generation(membership, pack_status_snapshot)

    # The pack was read independently of live membership and ticket status.
    # Neither runtime projection may turn a readable graph into a failed plan.
    health = ProviderHealth.new(source_generation, :healthy, true, observed_at: DateTime.utc_now())

    {health, status_health, source_generation}
  end

  @doc false
  @spec membership_health(term()) :: ProviderHealth.t()
  def membership_health(%{health: :healthy, freshness: %{status: :fresh}} = membership) do
    ProviderHealth.new(generation(membership), :healthy, true, observed_at: membership_observed_at(membership))
  end

  def membership_health(%{health: :healthy, freshness: %{status: status}} = membership)
      when status in [:stale, :unknown] do
    ProviderHealth.new(generation(membership), :stale, false, observed_at: membership_observed_at(membership), failure: :membership_stale)
  end

  def membership_health(%{health: :healthy, freshness: %{status: :unavailable}} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: membership_observed_at(membership),
      failure: :membership_unavailable
    )
  end

  def membership_health(%{health: {:degraded, _reason}} = membership) do
    ProviderHealth.new(generation(membership), :stale, false, observed_at: membership_observed_at(membership), failure: :membership_stale)
  end

  def membership_health(%{health: {:unavailable, _reason}} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: membership_observed_at(membership),
      failure: :membership_unavailable
    )
  end

  def membership_health(%{health: :unavailable} = membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: membership_observed_at(membership),
      failure: :membership_unavailable
    )
  end

  def membership_health(membership) do
    ProviderHealth.new(generation(membership), :unavailable, false,
      observed_at: membership_observed_at(membership),
      failure: :membership_unavailable
    )
  end

  defp membership_observed_at(%{freshness: %{last_observed_at: %DateTime{} = at}}), do: at
  defp membership_observed_at(_membership), do: nil

  defp pack_status_health(packs, snapshot) do
    packs
    |> pack_status_facts()
    |> project_pack_status_health(snapshot)
  end

  defp project_pack_status_health({false, _present?, _complete?}, _snapshot), do: nil

  defp project_pack_status_health({true, true, false}, snapshot) do
    %{snapshot | state: :stale, complete?: false, failure: snapshot.failure || :pack_status_incomplete}
  end

  defp project_pack_status_health({true, false, false}, snapshot) do
    %{snapshot | state: :unavailable, complete?: false, failure: snapshot.failure || :pack_status_incomplete}
  end

  defp project_pack_status_health({true, true, true}, %{state: :unavailable} = snapshot) do
    %{snapshot | state: :stale}
  end

  defp project_pack_status_health({true, _present?, true}, snapshot), do: snapshot

  defp pack_status_facts(packs) do
    Enum.reduce(packs, {false, false, true}, fn pack, facts ->
      Enum.reduce(pack.tickets, facts, fn ticket, {required?, projection_present?, projection_complete?} ->
        identity = ticket_identity(pack, ticket)
        requires_projection? = is_integer(ticket.number)
        known? = status_lifecycle(identity, pack) in [:completed, :cancelled, :open]

        {
          required? or requires_projection?,
          projection_present? or known?,
          projection_complete? and (not requires_projection? or known?)
        }
      end)
    end)
  end

  defp pack_status_health_snapshot do
    Application.get_env(:aiur, :build_order_pack_status_health_snapshot, &PackStatus.health/0).()
  rescue
    _error -> ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
  catch
    _kind, _reason -> ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
  end

  defp generation(%{generation: generation}) when is_integer(generation) and generation >= 0, do: @generation + generation
  defp generation(_membership), do: @generation

  defp source_generation(membership, %ProviderHealth{generation: pack_generation})
       when is_integer(pack_generation) and pack_generation > 0 do
    membership_generation = generation(membership)
    sum = membership_generation + pack_generation
    div(sum * (sum + 1), 2) + pack_generation
  end

  defp source_generation(membership, _pack_status), do: generation(membership)
end
