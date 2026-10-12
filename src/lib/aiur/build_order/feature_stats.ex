defmodule Aiur.BuildOrder.FeatureStats do
  @moduledoc "Pure feature figures over the complete registry, with explicit unknowns."
  alias Aiur.BuildOrder.History.Row
  alias Aiur.BuildOrder.Metadata
  alias Aiur.BuildOrder.ProgressRenderer
  @enforce_keys [:total, :done, :done_min, :pct, :pct_min, :orig, :added, :baseline?, :spark, :also, :reasons]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
  @type status :: :done | :failed | :not_planned | :closed | :running | :queued | :open | :unknown
  @type progress :: {:known, 0..100} | {:unknown, atom()}
  @type fact :: %{status: status(), complexity: 1..5 | :unknown, progress: progress()}
  @type registry :: %{features: map(), owners: map(), also: map()}
  @missing %{status: :unknown, complexity: :unknown, progress: {:unknown, :missing}}
  @day 86_400_000
  @spec points(1..5 | :unknown) :: pos_integer() | :unknown
  def points(1), do: 1
  def points(2), do: 2
  def points(3), do: 3
  def points(4), do: 5
  def points(5), do: 8
  def points(:unknown), do: :unknown
  @spec fact(Row.t() | :missing, status(), progress()) :: fact()
  def fact(row, status, progress) do
    labels = if row == :missing, do: :unknown, else: row.labels
    %{status: status, complexity: Metadata.parse(labels).complexity, progress: progress}
  end

  @spec compute_all(registry(), %{pos_integer() => fact()}, now: integer()) :: %{String.t() => t()}
  def compute_all(registry, facts, now: now) do
    owners = Enum.group_by(registry.owners, fn {_n, owner} -> owner.feature end)

    Map.new(registry.features, fn {slug, feature} ->
      members = Map.new(Map.get(owners, slug, []))
      {slug, compute(feature.baseline, members, facts, also_count(registry.also, slug, members), now)}
    end)
  end

  defp compute(baseline, members, facts, also, now) do
    member_facts = Enum.map(members, fn {n, _owner} -> Map.get(facts, n, @missing) end)
    done_min = Enum.count(member_facts, &(&1.status == :done))
    status_unknown = Enum.any?(member_facts, &(&1.status == :unknown))
    {pct_min, reasons} = completion(member_facts, status_unknown)
    added = added_count(baseline, members)

    %__MODULE__{
      total: map_size(members),
      done: if(status_unknown, do: nil, else: done_min),
      done_min: done_min,
      pct: if(reasons == [], do: pct_min),
      pct_min: pct_min,
      orig: map_size(members) - added,
      added: added,
      baseline?: baseline != :none,
      spark: spark(members, now),
      also: also,
      reasons: Enum.sort(reasons)
    }
  end

  defp completion(facts, status_unknown) do
    {weight, numerator, reasons} = Enum.reduce(facts, {0, 0, []}, &weight/2)
    reasons = Enum.uniq(if status_unknown, do: [:status | reasons], else: reasons)
    percentage(weight, numerator, reasons)
  end

  defp weight(%{status: status}, sums) when status in [:not_planned, :closed], do: sums
  defp weight(%{complexity: :unknown}, {w, n, reasons}), do: {w, n, [:complexity | reasons]}

  defp weight(fact, {w, n, reasons}) do
    p = points(fact.complexity)

    case fraction(fact) do
      {:known, x} -> {w + p, n + p * x, reasons}
      {:unknown, reason} -> {w + p, n, [reason | reasons]}
    end
  end

  defp fraction(%{status: status}) when status in [:done, :failed], do: {:known, 100}
  defp fraction(%{status: :running} = fact), do: fact |> running_contract() |> ProgressRenderer.json() |> Map.fetch!("progress") |> running_fraction()
  defp fraction(%{status: status}) when status in [:queued, :open], do: {:known, 0}
  defp fraction(%{status: :unknown}), do: {:unknown, :status}

  # A running member's reading becomes the RootSummary progress contract and is
  # resolved by ProgressRenderer; an unknown or out-of-range reading stays unknown.
  defp running_contract(%{progress: {:known, x}}), do: %{progress: x, progress_resolution: :resolved}
  defp running_contract(_fact), do: %{progress: nil, progress_resolution: :unknown}
  defp running_fraction(x) when is_integer(x), do: {:known, x}
  defp running_fraction(nil), do: {:unknown, :progress}

  defp percentage(w, n, reasons) do
    cond do
      :complexity in reasons -> {nil, reasons}
      w == 0 -> {nil, [:no_weight | reasons]}
      true -> {div(2 * n + w, 2 * w), reasons}
    end
  end

  defp added_count(:none, _members), do: 0
  defp added_count(baseline, members), do: Enum.count(members, fn {n, _} -> not MapSet.member?(baseline.members, n) end)
  defp also_count(also, slug, members), do: Enum.count(also, fn {n, links} -> slug in links and not Map.has_key?(members, n) end)

  defp spark(members, now) do
    joins = Enum.map(members, fn {_n, owner} -> DateTime.to_unix(owner.joined_at, :millisecond) end) |> Enum.sort()
    # ponytail: no scope-series cap; C12-T06 measures payloads before adding one.
    series =
      case joins do
        [first | _] when first <= now + 1 -> Enum.map(first..(now + 1)//@day, fn d -> Enum.count(joins, &(&1 <= d)) end)
        _ -> []
      end

    if List.last(series) == map_size(members), do: series, else: series ++ [map_size(members)]
  end

  @spec to_json(t()) :: map()
  def to_json(stats) do
    stats
    |> Map.from_struct()
    |> Map.delete(:baseline?)
    |> Map.put(:baseline, stats.baseline?)
    |> Map.update!(:reasons, fn reasons -> reasons |> Enum.uniq() |> Enum.sort() |> Enum.map(&Atom.to_string/1) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
