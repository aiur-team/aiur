defmodule Aiur.DecisionStore.RetainedIndex do
  @moduledoc false

  alias Aiur.Decision

  @lifecycle_statuses [:open, :deferred, :expired, :dismissed, :decided, :acknowledged, :resolved]
  @search_bucket_width 3

  @type t :: %{
          all: :gb_sets.set(),
          lifecycle: %{Decision.decision_status() => :gb_sets.set()},
          tickets: %{String.t() => :gb_sets.set()},
          searches: %{String.t() => :gb_sets.set()},
          audit_keys: %{String.t() => {integer(), String.t()}},
          current: %{
            all: :gb_sets.set(),
            lifecycle: %{Decision.decision_status() => :gb_sets.set()},
            tickets: %{String.t() => :gb_sets.set()},
            searches: %{String.t() => :gb_sets.set()},
            keys: %{String.t() => {integer(), String.t()}}
          },
          counts: %{
            open: non_neg_integer(),
            blocking: non_neg_integer(),
            deferred: non_neg_integer(),
            deferred_blocking: non_neg_integer()
          }
        }

  @spec build(%{String.t() => Decision.t()}, %{optional(String.t()) => [Decision.t()]}) :: t()
  def build(current, histories \\ %{}) do
    Enum.reduce(current, empty(), fn {_decision_id, decision}, index ->
      if operator_command?(decision) do
        add(index, decision, first_accepted_key(decision, Map.get(histories, decision.decision_id)))
      else
        index
      end
    end)
  end

  @spec update(t(), Decision.t() | nil, Decision.t()) :: t()
  def update(index, prior, %Decision{} = decision) do
    indexed? = Map.has_key?(index.audit_keys, decision.decision_id)

    case {indexed?, operator_command?(decision)} do
      {false, false} ->
        index

      {false, true} ->
        add(index, decision, audit_key(prior || decision))

      {true, false} ->
        remove(index, prior || decision)

      {true, true} ->
        key = Map.fetch!(index.audit_keys, decision.decision_id)
        index |> remove(prior) |> add(decision, key)
    end
  end

  @spec all(t(), :audit | :current) :: :gb_sets.set()
  def all(index, order \\ :audit), do: entries(index, order).all

  @spec lifecycle(t(), Decision.decision_status(), :audit | :current) :: :gb_sets.set()
  def lifecycle(index, status, order \\ :audit), do: entries(index, order).lifecycle |> Map.fetch!(status)

  @spec ticket(t(), String.t(), :audit | :current) :: :gb_sets.set()
  def ticket(index, value, order \\ :audit), do: bucket_entries(entries(index, order).tickets, value)

  @spec search(t(), String.t(), :audit | :current) :: :gb_sets.set()
  def search(index, value, order \\ :audit), do: bucket_entries(entries(index, order).searches, value)

  @spec canonical_counts(t()) :: %{
          open: non_neg_integer(),
          blocking: non_neg_integer(),
          deferred: non_neg_integer(),
          awaiting: non_neg_integer(),
          awaiting_blocking: non_neg_integer(),
          total: non_neg_integer()
        }
  # `open` stays the count of Commands no agent has an answer for — deferrals
  # included, because the unit is still blocked. `awaiting` is the subset the
  # operator personally still owns, and it is what the inbox lists. Both are
  # derived from the same index, so a surface can never show one and list the
  # other.
  def canonical_counts(index) do
    index.counts
    |> Map.take([:open, :blocking, :deferred])
    |> Map.merge(%{
      total: :gb_sets.size(index.all),
      awaiting: index.counts.open - index.counts.deferred,
      awaiting_blocking: index.counts.blocking - index.counts.deferred_blocking
    })
  end

  defp empty do
    lifecycle = Map.new(@lifecycle_statuses, &{&1, :gb_sets.empty()})

    %{
      all: :gb_sets.empty(),
      lifecycle: lifecycle,
      tickets: %{},
      searches: %{},
      audit_keys: %{},
      current: empty_entries(),
      counts: %{open: 0, blocking: 0, deferred: 0, deferred_blocking: 0}
    }
  end

  defp add(index, %Decision{} = decision, key) do
    ticket_buckets = buckets(ticket_identifier(decision))
    search_buckets = (buckets(decision.decision_id) ++ ticket_buckets) |> Enum.uniq()

    %{
      index
      | all: :gb_sets.add(key, index.all),
        lifecycle: Map.update!(index.lifecycle, decision.decision_status, &:gb_sets.add(key, &1)),
        tickets: add_buckets(index.tickets, ticket_buckets, key),
        searches: add_buckets(index.searches, search_buckets, key),
        audit_keys: Map.put(index.audit_keys, decision.decision_id, key),
        current: add_entries(index.current, decision, current_key(decision)),
        counts: increment_counts(index.counts, decision)
    }
  end

  defp remove(index, %Decision{} = decision) do
    key = Map.fetch!(index.audit_keys, decision.decision_id)
    ticket_buckets = buckets(ticket_identifier(decision))
    search_buckets = (buckets(decision.decision_id) ++ ticket_buckets) |> Enum.uniq()

    %{
      index
      | all: :gb_sets.delete_any(key, index.all),
        lifecycle: Map.update!(index.lifecycle, decision.decision_status, &:gb_sets.delete_any(key, &1)),
        tickets: remove_buckets(index.tickets, ticket_buckets, key),
        searches: remove_buckets(index.searches, search_buckets, key),
        audit_keys: Map.delete(index.audit_keys, decision.decision_id),
        current: remove_entries(index.current, decision),
        counts: decrement_counts(index.counts, decision)
    }
  end

  defp remove(index, _prior), do: index

  defp empty_entries do
    %{
      all: :gb_sets.empty(),
      lifecycle: Map.new(@lifecycle_statuses, &{&1, :gb_sets.empty()}),
      tickets: %{},
      searches: %{},
      keys: %{}
    }
  end

  defp add_entries(entries, %Decision{} = decision, key) do
    ticket_buckets = buckets(ticket_identifier(decision))
    search_buckets = (buckets(decision.decision_id) ++ ticket_buckets) |> Enum.uniq()

    %{
      entries
      | all: :gb_sets.add(key, entries.all),
        lifecycle: Map.update!(entries.lifecycle, decision.decision_status, &:gb_sets.add(key, &1)),
        tickets: add_buckets(entries.tickets, ticket_buckets, key),
        searches: add_buckets(entries.searches, search_buckets, key),
        keys: Map.put(entries.keys, decision.decision_id, key)
    }
  end

  defp remove_entries(entries, %Decision{} = decision) do
    key = Map.fetch!(entries.keys, decision.decision_id)
    ticket_buckets = buckets(ticket_identifier(decision))
    search_buckets = (buckets(decision.decision_id) ++ ticket_buckets) |> Enum.uniq()

    %{
      entries
      | all: :gb_sets.delete_any(key, entries.all),
        lifecycle: Map.update!(entries.lifecycle, decision.decision_status, &:gb_sets.delete_any(key, &1)),
        tickets: remove_buckets(entries.tickets, ticket_buckets, key),
        searches: remove_buckets(entries.searches, search_buckets, key),
        keys: Map.delete(entries.keys, decision.decision_id)
    }
  end

  defp add_buckets(index, buckets, key) do
    Enum.reduce(buckets, index, fn bucket, index ->
      Map.update(index, bucket, :gb_sets.add(key, :gb_sets.empty()), &:gb_sets.add(key, &1))
    end)
  end

  defp remove_buckets(index, buckets, key) do
    Enum.reduce(buckets, index, &remove_bucket(&2, &1, key))
  end

  defp remove_bucket(index, bucket, key) do
    entries = :gb_sets.delete_any(key, Map.get(index, bucket, :gb_sets.empty()))
    if :gb_sets.is_empty(entries), do: Map.delete(index, bucket), else: Map.put(index, bucket, entries)
  end

  defp bucket_entries(index, value), do: Map.get(index, bucket(value), :gb_sets.empty())

  defp buckets(value) when is_binary(value) and value != "" do
    value
    |> String.downcase()
    |> String.graphemes()
    |> Enum.take(@search_bucket_width)
    |> Enum.scan("", &(&2 <> &1))
  end

  defp buckets(_value), do: []

  defp bucket(value) do
    value
    |> String.downcase()
    |> String.graphemes()
    |> Enum.take(@search_bucket_width)
    |> Enum.join()
  end

  defp ticket_identifier(%Decision{ticket: ticket}), do: ticket && Map.get(ticket, :identifier)

  # Delivery and persistence failures are operational alerts about an existing
  # Command. They must never become a second operator-facing Command themselves.
  defp operator_command?(%Decision{legacy_attention: %{slug: slug}}) when is_binary(slug) do
    not String.starts_with?(slug, ["decision-delivery-", "decision-lifecycle-persistence-"])
  end

  defp operator_command?(%Decision{}), do: true

  defp increment_counts(counts, decision), do: adjust_counts(counts, decision, 1)
  defp decrement_counts(counts, decision), do: adjust_counts(counts, decision, -1)

  defp adjust_counts(counts, %Decision{decision_status: status, blocking: blocking}, delta)
       when status in [:open, :deferred] do
    blocking_delta = if blocking, do: delta, else: 0
    deferred_delta = if status == :deferred, do: delta, else: 0
    deferred_blocking_delta = if status == :deferred and blocking, do: delta, else: 0

    %{
      counts
      | open: counts.open + delta,
        blocking: counts.blocking + blocking_delta,
        deferred: counts.deferred + deferred_delta,
        deferred_blocking: counts.deferred_blocking + deferred_blocking_delta
    }
  end

  defp adjust_counts(counts, %Decision{}, _delta), do: counts
  defp first_accepted_key(_decision, [%Decision{} = first | _history]), do: audit_key(first)
  defp first_accepted_key(decision, _history), do: audit_key(decision)
  defp entries(index, :audit), do: index
  defp entries(index, :current), do: index.current

  defp audit_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end

  defp current_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end
end
