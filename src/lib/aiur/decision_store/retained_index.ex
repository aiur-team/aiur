defmodule Aiur.DecisionStore.RetainedIndex do
  @moduledoc false

  alias Aiur.Decision

  @lifecycle_statuses [:open, :decided, :acknowledged, :resolved]
  @search_bucket_width 3

  @type t :: %{
          all: :gb_sets.set(),
          lifecycle: %{Decision.decision_status() => :gb_sets.set()},
          tickets: %{String.t() => :gb_sets.set()},
          searches: %{String.t() => :gb_sets.set()},
          audit_keys: %{String.t() => {integer(), String.t()}},
          counts: %{open: non_neg_integer(), blocking: non_neg_integer()}
        }

  @spec build(%{String.t() => Decision.t()}, %{optional(String.t()) => [Decision.t()]}) :: t()
  def build(current, histories \\ %{}) do
    Enum.reduce(current, empty(), fn {_decision_id, decision}, index ->
      add(index, decision, first_accepted_key(decision, Map.get(histories, decision.decision_id)))
    end)
  end

  @spec update(t(), Decision.t() | nil, Decision.t()) :: t()
  def update(index, prior, %Decision{} = decision) do
    key = Map.get(index.audit_keys, decision.decision_id, audit_key(prior || decision))

    index
    |> remove(prior)
    |> add(decision, key)
  end

  @spec all(t()) :: :gb_sets.set()
  def all(index), do: index.all

  @spec lifecycle(t(), Decision.decision_status()) :: :gb_sets.set()
  def lifecycle(index, status), do: Map.fetch!(index.lifecycle, status)

  @spec ticket(t(), String.t()) :: :gb_sets.set()
  def ticket(index, value), do: bucket_entries(index.tickets, value)

  @spec search(t(), String.t()) :: :gb_sets.set()
  def search(index, value), do: bucket_entries(index.searches, value)

  @spec canonical_counts(t()) :: %{open: non_neg_integer(), blocking: non_neg_integer(), total: non_neg_integer()}
  def canonical_counts(index), do: Map.put(index.counts, :total, :gb_sets.size(index.all))

  defp empty do
    lifecycle = Map.new(@lifecycle_statuses, &{&1, :gb_sets.empty()})

    %{
      all: :gb_sets.empty(),
      lifecycle: lifecycle,
      tickets: %{},
      searches: %{},
      audit_keys: %{},
      counts: %{open: 0, blocking: 0}
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
        counts: decrement_counts(index.counts, decision)
    }
  end

  defp remove(index, _prior), do: index

  defp add_buckets(index, buckets, key) do
    Enum.reduce(buckets, index, fn bucket, index ->
      Map.update(index, bucket, :gb_sets.add(key, :gb_sets.empty()), &:gb_sets.add(key, &1))
    end)
  end

  defp remove_buckets(index, buckets, key) do
    Enum.reduce(buckets, index, fn bucket, index ->
      case Map.fetch(index, bucket) do
        {:ok, entries} ->
          entries = :gb_sets.delete_any(key, entries)
          if :gb_sets.is_empty(entries), do: Map.delete(index, bucket), else: Map.put(index, bucket, entries)

        :error ->
          index
      end
    end)
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

  defp increment_counts(counts, %Decision{decision_status: :open, blocking: blocking}) do
    %{counts | open: counts.open + 1, blocking: counts.blocking + if(blocking, do: 1, else: 0)}
  end

  defp increment_counts(counts, %Decision{}), do: counts

  defp decrement_counts(counts, %Decision{decision_status: :open, blocking: blocking}) do
    %{counts | open: counts.open - 1, blocking: counts.blocking - if(blocking, do: 1, else: 0)}
  end

  defp decrement_counts(counts, %Decision{}), do: counts
  defp first_accepted_key(_decision, [%Decision{} = first | _history]), do: audit_key(first)
  defp first_accepted_key(decision, _history), do: audit_key(decision)

  defp audit_key(%Decision{} = decision) do
    {-DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end
end
