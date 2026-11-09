defmodule Aiur.BuildOrder.Epics.Operations do
  @moduledoc """
  Event planning for the epic journal.

  Four operations write it: `create`, `edit`, `add` and `remove`. Each returns the
  events to append — an empty list means the request changed nothing. A repeated
  `create` with the same label, icon, hue and root, a repeated `add` of a feature
  already in the epic, and an `edit` with unchanged values all return `[]`.
  """

  alias Aiur.BuildOrder.Epics.EpicData
  alias Aiur.BuildOrder.Features.FeatureData
  alias Aiur.BuildOrder.Features.Operations, as: FeatureOperations

  @spec events(atom(), term(), term(), keyword(), map(), map()) :: {:ok, list()} | {:error, term()}
  def events(op, slug, input, metadata, projection, context) do
    with :ok <- check(EpicData.slug?(slug), :invalid_epic_slug),
         {:ok, meta} <- FeatureOperations.meta(metadata, context.now) do
      plan(op, slug, input, meta, projection, context)
    end
  end

  defp plan(:create, slug, input, _meta, projection, context) do
    with {:ok, epic} <- EpicData.create(slug, input, projection, context) do
      created(projection, epic, slug, context.now)
    end
  end

  defp plan(:edit, slug, input, _meta, projection, context) do
    with {:ok, epic} <- fetch(projection, slug),
         {:ok, changes} <- EpicData.update(epic, input, context.now) do
      events = if map_size(changes) == 0, do: [], else: [%{type: "epic.updated", epic: slug, changes: changes, at: context.now}]
      {:ok, events}
    end
  end

  defp plan(:add, slug, input, _meta, projection, context) do
    with {:ok, epic} <- fetch(projection, slug),
         {:ok, slugs} <- features(input),
         :ok <- known(context, slugs),
         :ok <- claimable(projection, epic.slug, slugs) do
      {:ok, for(feature <- slugs, feature not in epic.features, do: %{type: "epic.feature_added", epic: epic.slug, feature: feature, at: context.now})}
    end
  end

  defp plan(:remove, slug, input, _meta, projection, context) do
    with {:ok, epic} <- fetch(projection, slug),
         {:ok, slugs} <- features(input) do
      missing = Enum.reject(slugs, &(&1 in epic.features))

      with :ok <- check(missing == [], {:not_in_epic, missing}) do
        {:ok, Enum.map(slugs, &%{type: "epic.feature_removed", epic: epic.slug, feature: &1, at: context.now})}
      end
    end
  end

  defp plan(_op, _slug, _input, _meta, _projection, _context), do: {:error, :invalid_epic_operation}

  defp created(projection, epic, slug, now) do
    case Map.get(projection.epics, slug) do
      nil -> {:ok, [%{type: "epic.created", epic: epic, at: now}]}
      existing -> if(EpicData.same?(existing, epic), do: {:ok, []}, else: {:error, {:epic_exists, slug}})
    end
  end

  defp features(slugs) when is_list(slugs) do
    cond do
      length(slugs) > 200 -> {:error, :batch_too_large}
      not Enum.all?(slugs, &FeatureData.slug?/1) -> {:error, :invalid_feature_slug}
      true -> {:ok, Enum.uniq(slugs)}
    end
  end

  defp features(_), do: {:error, :invalid_feature_slug}

  defp known(context, slugs) do
    case Enum.find(slugs, &(not Map.has_key?(context.features.features, &1))) do
      nil -> :ok
      unknown -> {:error, {:unknown_feature, unknown}}
    end
  end

  defp claimable(projection, slug, slugs) do
    case Enum.find(slugs, &claimed_by(projection, slug, &1)) do
      nil -> :ok
      taken -> {:error, {:feature_in_epic, taken, claimed_by(projection, slug, taken)}}
    end
  end

  defp claimed_by(projection, slug, feature) do
    Enum.find_value(projection.epics, fn {other, epic} -> if other != slug and feature in epic.features, do: other end)
  end

  defp fetch(projection, slug) do
    case Map.get(projection.epics, slug) do
      nil -> {:error, {:unknown_epic, slug}}
      epic -> {:ok, epic}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
