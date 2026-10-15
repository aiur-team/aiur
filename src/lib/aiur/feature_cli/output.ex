defmodule Aiur.FeatureCLI.Output do
  @moduledoc false
  alias Aiur.BuildOrder.Features.LabelProjection

  @spec label_states(list(), keyword()) :: map()
  def label_states(ids, context) do
    case Keyword.get(context, :label_states, &LabelProjection.label_states/1).(ids) do
      {:ok, states} -> Map.new(ids, &{&1, label(Map.get(states, &1))})
      _ -> Map.new(ids, &{&1, "unknown"})
    end
  end

  @spec show(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def show(args, snapshot, context) do
    envelope = %{schema_version: 1, observed_at: Keyword.get(context, :clock, &DateTime.utc_now/0).()}

    case args[:slug] do
      nil ->
        features = snapshot.features |> Map.values() |> Enum.sort_by(& &1.slug) |> Enum.map(&summary(&1, snapshot))
        {:ok, Map.put(envelope, :features, features)}

      slug ->
        case snapshot.features[slug] do
          nil -> {:error, {:unknown_feature, slug}}
          feature -> {:ok, Map.merge(envelope, detail(feature, snapshot, context))}
        end
    end
  end

  defp detail(feature, snapshot, context) do
    owners = snapshot.owners |> Enum.filter(fn {_, owner} -> owner.feature == feature.slug end) |> Enum.sort_by(&elem(&1, 0))
    labels = label_states(Enum.map(owners, &elem(&1, 0)), context)
    members = Enum.map(owners, fn {id, owner} -> owner |> Map.drop([:feature]) |> Map.merge(%{id: id, label: labels[id]}) end)
    also = for {id, slugs} <- snapshot.also, feature.slug in slugs, do: id
    fields = feature |> Map.take([:label, :hue, :epics, :from, :to, :public_ref]) |> Map.put(:key, feature.slug)
    fields = fields |> Map.put(:baseline, baseline(feature.baseline, context)) |> Map.update!(:to, &nullable/1) |> Map.update!(:public_ref, &nullable/1)
    %{feature: fields, members: members, also: Enum.sort(also), labels: label_status(context)}
  end

  defp summary(feature, snapshot) do
    %{key: feature.slug, label: feature.label, members: Enum.count(snapshot.owners, fn {_, owner} -> owner.feature == feature.slug end), to: nullable(feature.to)}
  end

  defp label_status(context) do
    case Keyword.get(context, :label_status, &LabelProjection.status/0).() do
      %{pending: pending, failed: failed} when is_integer(pending) and is_list(failed) -> %{pending: pending, failed: length(failed)}
      _ -> nil
    end
  end

  @spec baseline(term(), keyword()) :: map() | nil
  def baseline(:none, _context), do: nil

  def baseline(%{at: at, members: members}, context) do
    now = Keyword.get(context, :clock, &DateTime.utc_now/0).()
    %{at: at, age_ms: max(DateTime.diff(now, at, :millisecond), 0), members: Enum.sort(members)}
  end

  @spec render(map()) :: String.t()
  def render(%{features: features}) do
    if features == [], do: "no features", else: Enum.map_join(features, "\n", &"#{&1.key}  #{&1.label}  #{&1.members} members  #{state(&1.to)}")
  end

  def render(%{members: members, feature: feature} = result) do
    rows = Enum.map_join(members, "", &"\n##{&1.id} epic #{&1.epic} #{&1.source} by #{&1.actor} joined #{time(&1.joined_at)} confirmed #{&1.confirmed} label #{&1.label}")
    base = if feature.baseline, do: baseline_text(feature.baseline), else: "no baseline: all #{length(members)} members count as original"
    labels = if result.labels, do: "labels: #{result.labels.pending} pending, #{result.labels.failed} failed", else: "label status unknown"

    "#{feature.key}  #{feature.label}  #{state(feature.to)} hue #{feature.hue}\nfrom #{time(feature.from)} to #{time(feature.to)}\nepics #{Enum.map_join(feature.epics, ", ", &(&1.key <> "=" <> &1.label))}\n#{base}\n#{labels}" <>
      rows <> "\nalso affects: #{Enum.join(result.also, ", ")}"
  end

  def render(result) do
    rows = Enum.map_join(result.results, ", ", fn row -> "##{row.id} #{row.outcome}" <> if(row[:label], do: " label #{row.label}", else: "") end)
    outcome = if result[:outcome], do: " #{result.outcome}", else: ""
    previous = if result[:previous_baseline], do: "\nreplaced #{baseline_text(result.previous_baseline)} (#{time(result.previous_baseline.at)})", else: ""
    "#{result.command} #{result.feature}#{outcome}: #{rows}" <> previous
  end

  @spec error(term()) :: String.t()
  def error({:unknown_feature, slug}), do: "unknown feature #{slug}; create it first"
  def error({:feature_exists, slug}), do: "feature #{slug} exists with different values; use aiur feature edit"
  def error({:owned_elsewhere, pairs}), do: "batch refused; owned elsewhere: " <> Enum.map_join(pairs, ", ", fn {id, slug} -> "#{id} (#{slug})" end)
  def error({:owner_cannot_also, ids}), do: "owners cannot also affect their feature: #{Enum.join(ids, ", ")}"
  def error({:not_member, ids}), do: "not members: #{Enum.join(ids, ", ")}; re-run to read current outcomes"
  def error({:baseline_exists, %{age_ms: _} = baseline}), do: baseline_text(baseline) <> "; pass --replace"
  def error({:baseline_exists, at}), do: "baseline already set #{time(at)}; pass --replace"
  def error(%{failure: reason}), do: "feature registry unavailable (#{inspect(reason)})"
  def error(reason) when reason in [:features_not_running, :version_unsupported, :state_dir_unavailable, :unsafe_path], do: "feature registry unavailable (#{reason})"
  def error({:journal_append_failed, reason}), do: "feature registry unavailable (journal append failed: #{inspect(reason)})"
  def error(reason), do: inspect(reason)
  defp label(:pending_label), do: "pending"
  defp label(:labelled), do: "labelled"
  defp label(:exempt), do: "exempt"
  defp label(:held_backfill), do: "held"
  defp label(:failed), do: "failed"
  defp label(_), do: "unknown"
  defp nullable(:none), do: nil
  defp nullable(value), do: value
  defp state(:unknown), do: "end unknown"
  defp state(nil), do: "open"
  defp state(_), do: "ended"
  defp time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp time(value), do: to_string(value)
  defp baseline_text(baseline), do: "baseline set #{age(baseline.age_ms)} ago with #{length(baseline.members)} members"
  defp age(ms) when ms >= 86_400_000, do: "#{div(ms, 86_400_000)}d"
  defp age(ms) when ms >= 3_600_000, do: "#{div(ms, 3_600_000)}h"
  defp age(ms) when ms >= 60_000, do: "#{div(ms, 60_000)}m"
  defp age(ms), do: "#{div(ms, 1_000)}s"
end
