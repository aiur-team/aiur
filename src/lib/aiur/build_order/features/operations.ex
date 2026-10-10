defmodule Aiur.BuildOrder.Features.Operations do
  @moduledoc false
  alias Aiur.BuildOrder.Features.FeatureData

  @spec events(atom(), term(), term(), keyword(), map(), map()) :: {:ok, list()} | {:error, term()}
  def events(op, slug, input, metadata, projection, context) do
    with :ok <- check(FeatureData.slug?(slug), :invalid_slug),
         {:ok, meta} <- meta(metadata, context.now) do
      plan(op, slug, input, meta, projection, context)
    end
  end

  @spec meta(term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def meta(metadata, now) when is_list(metadata) do
    if Keyword.keyword?(metadata) and length(Enum.uniq_by(metadata, &elem(&1, 0))) == length(metadata), do: validate_meta(metadata, now), else: {:error, :invalid_meta}
  end

  def meta(_, _), do: {:error, :invalid_meta}

  defp validate_meta(metadata, now) do
    meta = Map.new(metadata)
    meta = meta |> Map.put_new(:at, now) |> Map.put_new(:at_basis, :claimed) |> Map.put_new(:confirmed, meta[:source] != "backfill-agent")

    cond do
      not FeatureData.source?(meta[:source]) -> {:error, :invalid_source}
      not FeatureData.text?(meta[:actor], 100) -> {:error, :invalid_actor}
      not FeatureData.time?(meta.at) -> {:error, :invalid_at}
      future?(meta.at, now) -> {:error, :at_in_future}
      meta.at_basis not in [:claimed, :first_observed] -> {:error, :invalid_at_basis}
      not is_boolean(meta.confirmed) -> {:error, :invalid_confirmed}
      invalid_flags?(meta) -> {:error, :invalid_meta}
      true -> {:ok, meta}
    end
  end

  defp plan(:create, slug, input, _meta, projection, context) do
    with {:ok, general} <- general_epics(context),
         {:ok, feature} <- FeatureData.create(slug, input, context.now, general, projection.features) do
      create_events(feature, general, projection)
    end
  end

  defp plan(op, slug, input, meta, projection, context) do
    with {:ok, feature} <- fetch_feature(projection, slug) do
      change(op, feature, input, meta, projection, context)
    end
  end

  defp change(:update_feature, feature, input, _meta, _projection, context) do
    with {:ok, changes} <- FeatureData.update(feature, input, context.now) do
      events = if map_size(changes) == 0, do: [], else: [%{type: "feature.updated", feature: feature.slug, changes: changes, at: context.now}]
      {:ok, events}
    end
  end

  defp change(:add_epic, feature, input, _meta, projection, context) do
    with {:ok, general} <- general_epics(context),
         :ok <- check(not (is_map(input) and input[:key] == "unsorted"), {:epic_key_taken, "unsorted"}),
         :ok <- check(FeatureData.epic?(input), :invalid_epics) do
      epic_events(feature, input, general, projection, context.now)
    end
  end

  defp change(:add, feature, input, meta, projection, _context) do
    epic = Map.get(meta, :epic, hd(feature.epics).key)

    with {:ok, numbers} <- numbers(input),
         :ok <- check(Enum.any?(feature.epics, &(&1.key == epic)), {:unknown_epic, epic}),
         :ok <- ownership(numbers, feature.slug, meta, projection.owners) do
      {:ok, Enum.flat_map(numbers, &add_events(&1, feature.slug, epic, meta, projection))}
    end
  end

  defp change(:remove, feature, input, meta, projection, _context) do
    with {:ok, numbers} <- numbers(input) do
      nonmembers = Enum.reject(numbers, &match?(%{feature: slug} when slug == feature.slug, projection.owners[&1]))

      with :ok <- check(nonmembers == [], {:not_member, nonmembers}) do
        {:ok, Enum.map(numbers, &member_event("member.removed", feature.slug, &1, meta.at, %{reason: "remove"}))}
      end
    end
  end

  defp change(:also, feature, input, meta, projection, _context) do
    with :ok <- check(meta.source != "backfill-agent", :backfill_also_refused),
         {:ok, numbers} <- numbers(input) do
      owned = Enum.filter(numbers, &match?(%{feature: slug} when slug == feature.slug, projection.owners[&1]))

      with :ok <- check(owned == [], {:owner_cannot_also, owned}) do
        also_events(numbers, feature.slug, meta, projection)
      end
    end
  end

  defp change(:set_baseline, feature, _input, meta, projection, context) do
    case feature.baseline do
      %{at: at} when not is_map_key(meta, :replace) ->
        {:error, {:baseline_exists, at}}

      %{at: at} when meta.replace != true ->
        {:error, {:baseline_exists, at}}

      _ ->
        members = for {number, %{feature: slug}} <- projection.owners, slug == feature.slug, do: number
        {:ok, [%{type: "baseline.set", feature: feature.slug, at: context.now, members: Enum.sort(members)}]}
    end
  end

  defp change(_, _, _, _, _, _), do: {:error, :invalid_operation}

  defp create_events(feature, general, projection) do
    case projection.features[feature.slug] do
      nil ->
        with :ok <- FeatureData.available_epics(feature.epics, general, projection.features) do
          {:ok, [%{type: "feature.created", feature: feature.slug, data: feature}]}
        end

      existing ->
        fields = [:label, :hue, :hue_source, :epics, :from, :to, :public_ref]
        if Map.take(existing, fields) == Map.take(feature, fields), do: {:ok, []}, else: {:error, {:feature_exists, feature.slug}}
    end
  end

  defp epic_events(feature, input, general, projection, now) do
    case Enum.find(feature.epics, &(&1.key == input.key)) do
      ^input ->
        {:ok, []}

      nil ->
        with :ok <- FeatureData.available_epics([input], general, projection.features) do
          {:ok, [%{type: "feature.epic_added", feature: feature.slug, epic: input, at: now}]}
        end

      _ ->
        {:error, {:epic_key_taken, input.key}}
    end
  end

  defp also_events(numbers, slug, meta, projection) do
    remove? = Map.get(meta, :remove, false)
    type = if remove?, do: "also.removed", else: "also.added"
    events = for number <- numbers, linked?(projection, number, slug) != not remove?, do: member_event(type, slug, number, meta.at, %{})
    {:ok, events}
  end

  defp add_events(number, slug, epic, meta, projection) do
    owner = projection.owners[number]
    confirmed = meta.confirmed or match?(%{feature: ^slug, confirmed: true}, owner)
    label_echo? = String.starts_with?(meta.source, "label:") and match?(%{feature: ^slug, confirmed: true}, owner) and not Map.has_key?(meta, :epic)
    same? = label_echo? or match?(%{feature: ^slug, epic: ^epic, confirmed: ^confirmed}, owner)

    leave =
      case owner do
        %{feature: other} when other != slug -> [member_event("member.removed", other, number, meta.at, %{reason: "move"})]
        _ -> []
      end

    unlink = if linked?(projection, number, slug), do: [member_event("also.removed", slug, number, meta.at, %{})], else: []
    join = if same?, do: [], else: [member_event("member.added", slug, number, meta.at, %{epic: epic, confirmed: confirmed, at_basis: meta.at_basis})]
    leave ++ unlink ++ join
  end

  defp ownership(numbers, slug, meta, owners) do
    conflicts =
      for number <- numbers, owner = owners[number], owner && owner.feature != slug, not (Map.get(meta, :move, false) and (meta.confirmed or not owner.confirmed)), do: {number, owner.feature}

    check(conflicts == [], {:owned_elsewhere, conflicts})
  end

  defp numbers(input) when is_list(input) do
    cond do
      length(input) > 1_000 -> {:error, :batch_too_large}
      not Enum.all?(input, &(is_integer(&1) and &1 > 0 and &1 < 2_147_483_648)) -> {:error, :invalid_number}
      true -> {:ok, Enum.sort(Enum.uniq(input))}
    end
  end

  defp numbers(_), do: {:error, :invalid_number}
  defp member_event(type, slug, number, at, extra), do: Map.merge(%{type: type, feature: slug, number: number, at: at}, extra)
  defp linked?(projection, number, slug), do: MapSet.member?(Map.get(projection.also, number, MapSet.new()), slug)

  defp fetch_feature(projection, slug) do
    case projection.features[slug] do
      nil -> {:error, {:unknown_feature, slug}}
      feature -> {:ok, feature}
    end
  end

  defp general_epics(context) do
    case context.general_epics.() do
      {:ok, epics} when is_list(epics) ->
        if Enum.all?(epics, &valid_general_epic?/1), do: {:ok, epics}, else: {:error, :epic_config_unavailable}

      _ ->
        {:error, :epic_config_unavailable}
    end
  rescue
    _ -> {:error, :epic_config_unavailable}
  catch
    :exit, _ -> {:error, :epic_config_unavailable}
  end

  defp valid_general_epic?(%{key: key, hue: hue}), do: is_binary(key) and key != "" and FeatureData.hue?(hue)
  defp valid_general_epic?(_), do: false

  defp invalid_flags?(meta), do: Enum.any?([:move, :remove, :replace], &(Map.has_key?(meta, &1) and not is_boolean(meta[&1])))

  defp future?(:unknown, _), do: false
  defp future?(at, now), do: DateTime.diff(at, now, :microsecond) > 300_000_000
  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
end
