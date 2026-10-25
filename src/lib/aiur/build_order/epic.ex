defmodule Aiur.BuildOrder.Epic do
  @moduledoc """
  Resolves home-page general and feature epics, distinct from Build Order
  `build-lane:` lanes and their `epic_count`. Lane labels only match when
  explicitly listed in `build_order.general_epics`.

  Context contains `general` (ordered, normalized GeneralEpic maps or structs)
  and `features` (feature slug to ordered epic keys, or `:unknown`). Ticket
  facts contain `labels`, optional `labels_complete` (default true),
  `owning_feature` and `override` records (default `:none`). Missing labels
  are unknown. Extra record fields are ignored.
  """

  defmodule Resolution do
    @moduledoc "One epic decision, with ignored signals and unavailable inputs."
    @enforce_keys [:key, :source]
    defstruct [:key, :source, ignored: [], gaps: []]
    @type t :: %__MODULE__{key: String.t(), source: String.t(), ignored: [atom()], gaps: [atom()]}
  end

  @spec resolve(map(), map()) :: Resolution.t()
  def resolve(ticket, %{general: general, features: features}) do
    owner = Map.get(ticket, :owning_feature, :none)
    override = Map.get(ticket, :override, :none)
    acc = %{ignored: [], gaps: []}

    with {:next, acc} <- feature(owner, features, override, acc),
         {:next, acc} <- override(override, general, acc),
         {:next, acc} <- labels(ticket, general, acc) do
      fallback(acc)
    else
      {:done, resolution} -> resolution
    end
  end

  @spec unsorted() :: map()
  def unsorted, do: %{key: "unsorted", label: "Unsorted", hue: 0, icon: "unsorted", unsorted: true}

  defp feature(owner, features, _override, acc) when owner == :unknown or features == :unknown,
    do: {:next, gap(acc, :feature)}

  defp feature(:none, _features, _override, acc), do: {:next, acc}

  defp feature(%{feature: slug, epic: epic}, features, override, acc) do
    case Map.fetch(features, slug) do
      :error -> {:next, ignore(acc, :feature_missing)}
      {:ok, []} -> {:next, ignore(acc, :feature_without_epics)}
      {:ok, [first | _] = epics} -> feature_epic(epic, epics, first, override, acc)
    end
  end

  defp feature_epic(epic, epics, first, override, acc) do
    {key, acc} = if epic in epics, do: {epic, acc}, else: {first, ignore(acc, :owner_epic_missing)}
    acc = if is_map(override), do: ignore(acc, :override_outside_feature), else: acc
    {:done, resolution(key, "feature", acc)}
  end

  defp override(:unknown, _general, acc), do: {:next, gap(acc, :override)}
  defp override(:none, _general, acc), do: {:next, acc}

  defp override(%{epic: epic, actor: actor}, general, acc) do
    if Enum.any?(general, &(&1.key == epic)),
      do: {:done, resolution(epic, "override:" <> actor, acc)},
      else: {:next, ignore(acc, :override_unknown_epic)}
  end

  defp labels(ticket, general, acc) do
    case Map.get(ticket, :labels, :unknown) do
      :unknown -> {:next, gap(acc, :labels)}
      labels when is_list(labels) -> match_labels(normalize(labels), ticket, general, acc)
    end
  end

  defp match_labels(labels, ticket, general, acc) do
    match =
      Enum.find_value(general, fn epic ->
        case Enum.find(epic.labels, &MapSet.member?(labels, &1)) do
          nil -> nil
          label -> {epic.key, label}
        end
      end)

    case match do
      {key, label} -> {:done, resolution(key, "label:" <> label, acc)}
      nil -> {:next, if(Map.get(ticket, :labels_complete, true) == true, do: acc, else: gap(acc, :labels))}
    end
  end

  defp normalize(labels) do
    labels
    |> Enum.filter(&(is_binary(&1) and String.valid?(&1) and byte_size(&1) in 1..256))
    |> MapSet.new(&(String.trim(&1) |> String.downcase()))
  end

  defp fallback(acc), do: resolution("unsorted", if(acc.gaps == [], do: "default", else: "unknown"), acc)
  defp resolution(key, source, acc), do: struct!(Resolution, Map.merge(acc, %{key: key, source: source}))
  defp ignore(acc, reason), do: %{acc | ignored: acc.ignored ++ [reason]}
  defp gap(acc, input), do: %{acc | gaps: acc.gaps ++ [input]}
end
