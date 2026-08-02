defmodule Aiur.Usage.GroupedScopes.Scope do
  @moduledoc """
  Explicit typed scope authority for a grouped usage query.

  A request declares exactly one of three shapes:

    * `this_run/1` — a single opaque run identity.
    * `explicit_ticket_set/1` — repository-qualified typed ticket identities.
    * `intersection/2` — a run identity *and* a ticket set, matched
      conjunctively (a cell counts only when it belongs to the run **and** to a
      member ticket).

  Bare issue numbers, visible rows, and labels are never scope authority: only
  non-empty opaque run-id strings and `Aiur.TrackerIdentity` structs that
  resolve to a GitHub key are accepted. Non-joinable ticket identities are
  rejected and counted, never silently coerced into a scope key.

  Membership — which tickets are current members of a build — is supplied by the
  caller (DASH-023 translates selected GitHub membership into an explicit ticket
  set). This module never stores, infers, or mutates membership; an explicit
  ticket set is matched against every retained cell, so pre-membership usage for
  a current member is included and non-members are excluded.
  """

  alias Aiur.TrackerIdentity
  alias Aiur.UsageAggregate.Key

  @enforce_keys [:kind]
  defstruct kind: nil, run_id: nil, ticket_keys: MapSet.new(), rejected_tickets: 0

  @type kind :: :this_run | :explicit_ticket_set | :intersection
  @type t :: %__MODULE__{
          kind: kind(),
          run_id: String.t() | nil,
          ticket_keys: MapSet.t(Key.ticket()),
          rejected_tickets: non_neg_integer()
        }

  @doc "Scopes to a single opaque run identity."
  @spec this_run(String.t()) :: {:ok, t()} | {:error, :invalid_run_identity}
  def this_run(run_id) when is_binary(run_id) and run_id != "" do
    {:ok, %__MODULE__{kind: :this_run, run_id: run_id}}
  end

  def this_run(_run_id), do: {:error, :invalid_run_identity}

  @doc """
  Scopes to an explicit set of repository-qualified typed ticket identities.

  An empty (or fully rejected) set is valid and yields a `:known_empty`
  projection; non-joinable identities are counted in `rejected_tickets`.
  """
  @spec explicit_ticket_set([TrackerIdentity.t()]) :: {:ok, t()} | {:error, :invalid_ticket_set}
  def explicit_ticket_set(tickets) when is_list(tickets) do
    {keys, rejected} = normalize_tickets(tickets)
    {:ok, %__MODULE__{kind: :explicit_ticket_set, ticket_keys: keys, rejected_tickets: rejected}}
  end

  def explicit_ticket_set(_tickets), do: {:error, :invalid_ticket_set}

  @doc "Scopes to the intersection of one run identity and an explicit ticket set."
  @spec intersection(String.t(), [TrackerIdentity.t()]) ::
          {:ok, t()} | {:error, :invalid_run_identity | :invalid_ticket_set}
  def intersection(run_id, tickets) when is_binary(run_id) and run_id != "" and is_list(tickets) do
    {keys, rejected} = normalize_tickets(tickets)
    {:ok, %__MODULE__{kind: :intersection, run_id: run_id, ticket_keys: keys, rejected_tickets: rejected}}
  end

  def intersection(run_id, _tickets) when not is_binary(run_id) or run_id == "",
    do: {:error, :invalid_run_identity}

  def intersection(_run_id, _tickets), do: {:error, :invalid_ticket_set}

  @doc """
  Returns whether a cell's identity dimensions fall inside this scope.

  Uses the same `Aiur.UsageAggregate.Key` ticket key the projection stored, so a
  `TrackerIdentity` and its aggregated cell compare exactly.
  """
  @spec matches?(t(), Key.dims()) :: boolean()
  def matches?(%__MODULE__{kind: :this_run, run_id: run_id}, %{run_id: cell_run}),
    do: cell_run == run_id

  def matches?(%__MODULE__{kind: :explicit_ticket_set, ticket_keys: keys}, %{ticket: ticket}),
    do: MapSet.member?(keys, ticket)

  def matches?(%__MODULE__{kind: :intersection, run_id: run_id, ticket_keys: keys}, %{
        run_id: cell_run,
        ticket: ticket
      }),
      do: cell_run == run_id and MapSet.member?(keys, ticket)

  @doc "Returns whether the scope can select any cell at all."
  @spec selectable?(t()) :: boolean()
  def selectable?(%__MODULE__{kind: :this_run}), do: true
  def selectable?(%__MODULE__{kind: :explicit_ticket_set, ticket_keys: keys}), do: MapSet.size(keys) > 0

  def selectable?(%__MODULE__{kind: :intersection, ticket_keys: keys}),
    do: MapSet.size(keys) > 0

  @doc "A content-free, canonically ordered description of the scope for a snapshot."
  @spec public(t()) :: map()
  def public(%__MODULE__{} = scope) do
    %{
      kind: scope.kind,
      run_id: scope.run_id,
      tickets: scope.ticket_keys |> MapSet.to_list() |> Enum.sort(),
      rejected_tickets: scope.rejected_tickets,
      status: if(selectable?(scope), do: :scoped, else: :empty)
    }
  end

  defp normalize_tickets(tickets) do
    Enum.reduce(tickets, {MapSet.new(), 0}, fn ticket, {keys, rejected} ->
      case ticket_key(ticket) do
        {:ok, key} -> {MapSet.put(keys, key), rejected}
        :error -> {keys, rejected + 1}
      end
    end)
  end

  defp ticket_key(%TrackerIdentity{} = identity) do
    case TrackerIdentity.github_key(identity) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  defp ticket_key(_ticket), do: :error
end
