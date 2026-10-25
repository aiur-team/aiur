defmodule Aiur.FeatureCLI.Arguments do
  @moduledoc false
  alias Aiur.BuildOrder.Features.FeatureData

  @spec validate(map()) :: :ok | {:usage, String.t()}
  def validate(args) do
    op = args[:op]

    with :ok <- operation(op, args),
         :ok <- fields(args),
         :ok <- provenance(op, args),
         :ok <- epics(args) do
      end_time(args[:end])
    end
  end

  defp operation(op, args) do
    cond do
      op not in [:create, :add, :remove, :also, :baseline, :edit, :show] -> usage("unknown operation")
      not valid_slug?(op, args[:slug]) -> usage("invalid feature slug")
      op in [:add, :remove, :also] and not ids?(args[:ids]) -> usage("requires 1 to 200 issue numbers below 2^31")
      op == :create and not Map.has_key?(args, :label) -> usage("create requires --label")
      op == :edit -> edit(args)
      true -> :ok
    end
  end

  defp valid_slug?(:show, nil), do: true
  defp valid_slug?(_op, slug), do: FeatureData.slug?(slug)

  defp edit(args) do
    if Enum.any?([:label, :hue, :end, :add_epics], &Map.has_key?(args, &1)), do: :ok, else: usage("edit requires at least one change")
  end

  defp fields(args) do
    cond do
      Map.has_key?(args, :hue) and not FeatureData.hue?(args.hue) -> usage("hue must be 0 to 359")
      Map.has_key?(args, :label) and not FeatureData.text?(args.label, 80) -> usage("invalid label")
      not flags?(args) -> usage("invalid boolean option")
      true -> :ok
    end
  end

  defp provenance(op, args) do
    cond do
      args[:source] not in [nil, "backfill-agent"] -> usage("invalid source")
      args[:source] == "backfill-agent" and op != :add -> usage("backfill source requires add")
      args[:backfill] == true and op != :add -> usage("backfill requires add")
      true -> :ok
    end
  end

  defp epics(args) do
    cond do
      not epics?(args[:epics]) or not epics?(args[:add_epics]) -> usage("invalid epic key=label")
      Map.has_key?(args, :epic) and not FeatureData.epic_key?(args.epic) -> usage("invalid epic key")
      true -> :ok
    end
  end

  @spec end_time(term()) :: :ok | {:usage, String.t()}
  def end_time(nil), do: :ok
  def end_time("now"), do: :ok

  def end_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> :ok
      _ -> usage("end must be now or ISO-8601")
    end
  end

  def end_time(_), do: usage("end must be now or ISO-8601")
  defp ids?(ids), do: is_list(ids) and length(ids) in 1..200 and Enum.all?(ids, &(is_integer(&1) and &1 in 1..2_147_483_647))
  defp epics?(nil), do: true
  defp epics?(epics), do: is_list(epics) and epics != [] and Enum.all?(epics, &FeatureData.epic?/1) and length(Enum.uniq_by(epics, & &1.key)) == length(epics)
  defp flags?(args), do: Enum.all?([:move, :remove, :replace, :backfill], &(not Map.has_key?(args, &1) or is_boolean(args[&1])))
  defp usage(message), do: {:usage, message}
end
