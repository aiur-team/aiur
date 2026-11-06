defmodule Aiur.BuildOrder.Epics.EpicData do
  @moduledoc """
  Validation and defaults for one epic record.

  An epic carries a slug (the same shape as a feature slug), a label, an
  optional Heroicon, a hue and an optional Build Order root. A root belongs to at
  most one epic. A missing hue follows the registry feature of the same slug when
  there is one — which is how an imported Build Order root keeps its colour —
  and otherwise takes the deterministic auto hue.
  """

  alias Aiur.BuildOrder.Features.FeatureData

  @editable [:label, :icon, :hue, :root]
  @updatable [:label, :icon, :hue]

  @spec slug?(term()) :: boolean()
  def slug?(value), do: FeatureData.slug?(value)

  @spec create(term(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create(slug, input, projection, context) when is_map(input) do
    with :ok <- check(slug?(slug), :invalid_epic_slug),
         :ok <- check(Enum.all?(Map.keys(input), &(&1 in @editable)), :invalid_epic),
         :ok <- check(FeatureData.text?(input[:label], 80), :invalid_label),
         {:ok, icon} <- icon(input[:icon]),
         {:ok, hue} <- hue(input[:hue], slug, context),
         {:ok, root} <- root(input[:root], slug),
         :ok <- available_root(root, slug, projection) do
      {:ok, %{slug: slug, label: input.label, icon: icon, hue: hue, root: root}}
    end
  end

  def create(_slug, _input, _projection, _context), do: {:error, :invalid_epic}

  @spec update(map(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(epic, changes, _now) when is_map(changes) do
    with :ok <- check(Enum.all?(Map.keys(changes), &(&1 in @updatable)), :invalid_epic),
         {:ok, icon} <- icon(Map.get(changes, :icon, epic.icon)),
         :ok <- check(FeatureData.text?(Map.get(changes, :label, epic.label), 80), :invalid_label),
         :ok <- check(FeatureData.hue?(Map.get(changes, :hue, epic.hue)), :invalid_hue) do
      {:ok, Map.reject(Map.put(changes, :icon, icon), fn {key, value} -> epic[key] == value end)}
    end
  end

  def update(_epic, _changes, _now), do: {:error, :invalid_epic}

  @doc "Whether two epic records describe the same label, icon, hue and root."
  @spec same?(map(), map()) :: boolean()
  def same?(left, right), do: Map.take(left, [:label, :icon, :hue, :root]) == Map.take(right, [:label, :icon, :hue, :root])

  defp icon(nil), do: {:ok, nil}
  defp icon(value), do: if(Aiur.Heroicons.valid?(value), do: {:ok, value}, else: {:error, :invalid_icon})

  defp hue(nil, slug, context) do
    features = Map.get(context, :features, %{features: %{}})

    case Map.get(features.features, slug) do
      %{hue: hue} when is_integer(hue) -> {:ok, hue}
      _ -> {:ok, FeatureData.auto_hue(slug, Map.get(context, :lanes, []), features.features)}
    end
  end

  defp hue(value, _slug, _context), do: if(FeatureData.hue?(value), do: {:ok, value}, else: {:error, :invalid_hue})

  defp root(nil, slug), do: {:ok, root_number(slug)}
  defp root(value, _slug) when is_integer(value) and value > 0 and value < 2_147_483_648, do: {:ok, value}
  defp root(_value, _slug), do: {:error, :invalid_root}

  defp root_number(slug) do
    case Regex.run(~r/^bo-([0-9]{1,10})$/, slug) do
      [_, number] -> String.to_integer(number)
      nil -> nil
    end
  end

  defp available_root(nil, _slug, _projection), do: :ok

  defp available_root(root, slug, projection) do
    taken = Enum.find(projection.epics, fn {other, epic} -> other != slug and epic.root == root end)
    if taken, do: {:error, {:root_taken, root, elem(taken, 0)}}, else: :ok
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
