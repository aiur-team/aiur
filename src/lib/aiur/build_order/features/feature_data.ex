defmodule Aiur.BuildOrder.Features.FeatureData do
  @moduledoc false
  alias Aiur.Heroicons
  @hues [175, 55, 285, 128, 232, 18, 330, 80, 250, 150, 272]
  @palette [
    {"red", 8},
    {"green", 120},
    {"yellow", 55},
    {"blue", 215},
    {"purple", 280},
    {"aqua", 170},
    {"orange", 25},
    {"bright-red", 4},
    {"bright-green", 124},
    {"bright-yellow", 59},
    {"bright-blue", 219},
    {"bright-purple", 284},
    {"bright-aqua", 174},
    {"bright-orange", 29},
    {"faded-red", 0},
    {"faded-green", 116},
    {"faded-yellow", 51},
    {"faded-blue", 211},
    {"faded-purple", 276},
    {"faded-aqua", 166},
    {"faded-orange", 21}
  ]
  @editable [:label, :hue, :from, :to, :public_ref, :epics]

  @spec source?(term()) :: boolean()
  def source?(value), do: matches?(value, ~r/^(?:(cli|agent|label|inherited|import):[A-Za-z0-9._\-\[\]]{1,64}|backfill-agent)\z/)

  @spec slug?(term()) :: boolean()
  def slug?(value), do: matches?(value, ~r/^[a-z0-9][a-z0-9-]{0,41}\z/)
  @spec epic_key?(term()) :: boolean()
  def epic_key?(value), do: matches?(value, ~r/^[a-z0-9][a-z0-9-]{0,63}\z/) and value != "unsorted"
  @spec hue?(term()) :: boolean()
  def hue?(value), do: is_integer(value) and value in 0..359
  @spec time?(term()) :: boolean()
  def time?(:unknown), do: true
  def time?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  def time?(_), do: false
  @spec end_time?(term()) :: boolean()
  def end_time?(:none), do: true
  def end_time?(value), do: time?(value)
  @spec public_ref?(term()) :: boolean()
  def public_ref?(:none), do: true
  def public_ref?(value), do: matches?(value, ~r/^MP-(E|N)[0-9]+\z/)

  @spec text?(term(), pos_integer()) :: boolean()
  def text?(value, max) do
    is_binary(value) and String.valid?(value) and String.length(value) in 1..max and not Regex.match?(~r/\p{Cc}/u, value)
  end

  @spec epic?(term()) :: boolean()
  def epic?(%{key: key, label: label} = epic) do
    Map.keys(epic) -- [:key, :label, :hue, :color, :icon] == [] and epic_key?(key) and text?(label, 80) and
      (not Map.has_key?(epic, :hue) or hue?(epic.hue)) and
      (not Map.has_key?(epic, :color) or gruvbox_hue(epic.color) != :error) and
      (not Map.has_key?(epic, :icon) or Heroicons.valid?(epic.icon))
  end

  def epic?(_), do: false

  @spec gruvbox_hue(term()) :: {String.t(), non_neg_integer()} | :error
  def gruvbox_hue(name) when is_binary(name), do: Enum.find(@palette, :error, fn {candidate, _} -> candidate == name end)
  def gruvbox_hue(_), do: :error

  @spec palette_hue(term()) :: {:ok, non_neg_integer()} | :error
  def palette_hue(name) do
    case gruvbox_hue(name) do
      {^name, hue} -> {:ok, hue}
      _ -> :error
    end
  end

  @spec epic_palette_name(map()) :: String.t() | nil
  def epic_palette_name(%{color: color}) when is_binary(color), do: color

  def epic_palette_name(%{hue: hue}) when is_integer(hue) do
    case Enum.find(@palette, fn {_name, candidate} -> candidate == hue end) do
      {name, _hue} -> name
      nil -> nil
    end
  end

  def epic_palette_name(_epic), do: nil

  @spec used_epic_colors(list(), map()) :: [String.t()]
  def used_epic_colors(general, features) do
    general_colors = Enum.with_index(general) |> Enum.map(fn {epic, index} -> Map.get(epic, :color) || palette_name(index) end)

    features
    |> Enum.sort_by(fn {slug, feature} -> {Map.get(feature, :created_at, Map.get(feature, :from)), slug} end)
    |> Enum.reduce(MapSet.new(general_colors), fn {_slug, feature}, used ->
      feature.epics |> assign_epic_colors(MapSet.to_list(used)) |> add_epic_colors(used)
    end)
    |> MapSet.to_list()
  end

  @spec assign_epic_colors([map()]) :: [map()]
  def assign_epic_colors(epics), do: assign_epic_colors(epics, [])

  @spec assign_epic_colors([map()], [String.t()]) :: [map()]
  def assign_epic_colors(epics, used) do
    used = MapSet.new(used)
    Enum.map_reduce(epics, used, &assign_epic_color/2) |> elem(0)
  end

  defp assign_epic_color(epic, taken) do
    if Map.has_key?(epic, :hue) or Map.has_key?(epic, :color),
      do: {epic, mark_epic_color_used(epic, taken)},
      else: assign_next_epic_color(epic, taken)
  end

  defp mark_epic_color_used(epic, taken) do
    case epic_palette_name(epic) do
      nil -> taken
      name -> MapSet.put(taken, name)
    end
  end

  defp add_epic_colors(epics, used), do: Enum.reduce(epics, used, &add_epic_color/2)
  defp add_epic_color(epic, used), do: maybe_add_epic_color(epic_palette_name(epic), used)
  defp maybe_add_epic_color(nil, used), do: used
  defp maybe_add_epic_color(name, used), do: MapSet.put(used, name)

  defp assign_next_epic_color(epic, taken) do
    case Enum.find(@palette, fn {name, _} -> not MapSet.member?(taken, name) end) do
      {name, hue} -> {Map.merge(epic, %{color: name, hue: hue}), MapSet.put(taken, name)}
      nil -> {epic, taken}
    end
  end

  @spec create(term(), term(), DateTime.t(), list(), map()) :: {:ok, map()} | {:error, term()}
  def create(slug, input, now, general_epics, features) when is_map(input) do
    with :ok <- check(slug?(slug), :invalid_slug),
         :ok <- check(Enum.all?(Map.keys(input), &(&1 in @editable)), :invalid_feature),
         :ok <- check(text?(input[:label], 80), :invalid_label) do
      existing = features[slug]
      hue = default(input[:hue], if(existing, do: existing.hue, else: auto_hue(slug, general_epics, features)))

      feature = %{
        slug: slug,
        label: input.label,
        hue: hue,
        hue_source: if(is_nil(input[:hue]), do: if(existing, do: existing.hue_source, else: :auto), else: :explicit),
        epics: create_epics(input, existing, general_epics, features, slug),
        from: default(input[:from], if(existing, do: existing.created_at, else: now)),
        to: default(input[:to], :none),
        baseline: :none,
        public_ref: default(input[:public_ref], :none),
        created_at: if(existing, do: existing.created_at, else: now),
        updated_at: now
      }

      with :ok <- fields(feature), do: {:ok, feature}
    end
  end

  def create(_, _, _, _, _), do: {:error, :invalid_feature}

  @spec update(map(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(feature, changes, now) when is_map(changes) do
    with :ok <- check(Enum.all?(Map.keys(changes), &(&1 in @editable)), :invalid_feature),
         {:ok, epics} <- relabel(feature.epics, Map.get(changes, :epics, [])) do
      changes = if Map.has_key?(changes, :epics), do: Map.put(changes, :epics, epics), else: changes
      changes = if Map.has_key?(changes, :hue), do: Map.put(changes, :hue_source, :explicit), else: changes
      candidate = feature |> Map.merge(changes) |> Map.put(:updated_at, now)

      with :ok <- fields(candidate) do
        changed = changed_fields(changes, feature)
        {:ok, changed}
      end
    end
  end

  def update(_, _, _), do: {:error, :invalid_feature}

  @spec available_epics(list(), list(), map(), String.t() | nil) :: :ok | {:error, term()}
  def available_epics(epics, general, features, own_slug \\ nil) do
    occupied = for {slug, feature} <- features, slug != own_slug, epic <- feature.epics, do: epic.key
    keys = Enum.map(epics, & &1.key)
    taken = Enum.find(keys, &(&1 == "unsorted" or &1 in occupied or Enum.any?(general, fn epic -> epic.key == &1 end)))

    cond do
      taken -> {:error, {:epic_key_taken, taken}}
      length(Enum.uniq(keys)) != length(keys) -> {:error, {:epic_key_taken, duplicate(keys)}}
      true -> :ok
    end
  end

  @spec auto_hue(String.t(), list(), map()) :: non_neg_integer()
  def auto_hue(slug, general, features) do
    filtered = Enum.reject(@hues, fn hue -> Enum.any?(general, &(distance(hue, &1.hue) <= 15)) end)
    candidates = if filtered == [], do: @hues, else: filtered
    start = rem(:binary.decode_unsigned(binary_part(:crypto.hash(:sha256, slug), 0, 4)), length(candidates))
    rotated = Enum.drop(candidates, start) ++ Enum.take(candidates, start)
    used = for {_, feature} <- features, feature.to == :none, do: feature.hue
    Enum.find(rotated, hd(rotated), &(&1 not in used))
  end

  defp create_epics(input, existing, general, features, slug) do
    case input[:epics] do
      nil when not is_nil(existing) ->
        assign_epic_colors(existing.epics, used_epic_colors(general, Map.delete(features, slug)))

      nil ->
        assign_epic_colors([%{key: "f-" <> slug, label: input.label}], used_epic_colors(general, features))

      requested ->
        epics = preserve_epic_metadata(requested, existing)
        assign_epic_colors(epics, used_epic_colors(general, Map.delete(features, slug)))
    end
  end

  defp preserve_epic_metadata(requested, existing) do
    previous = if existing, do: existing.epics, else: []
    Enum.map(requested, fn epic -> merge_epic_metadata(epic, previous) end)
  end

  defp merge_epic_metadata(epic, previous) do
    case Enum.find(previous, &(&1.key == epic.key)) do
      nil -> epic
      stored -> Map.merge(stored, epic)
    end
  end

  defp palette_name(index), do: elem(Enum.at(@palette, rem(index, length(@palette))), 0)

  defp fields(feature) do
    cond do
      not text?(feature.label, 80) -> {:error, :invalid_label}
      not hue?(feature.hue) -> {:error, :invalid_hue}
      reserved_epic?(feature.epics) -> {:error, {:epic_key_taken, "unsorted"}}
      not epics?(feature.epics) -> {:error, :invalid_epics}
      not time?(feature.from) -> {:error, :invalid_from}
      not end_time?(feature.to) -> {:error, :invalid_to}
      not public_ref?(feature.public_ref) -> {:error, :invalid_public_ref}
      true -> :ok
    end
  end

  defp changed_fields(changes, feature), do: Map.reject(changes, fn {key, value} -> feature[key] == value end)
  defp reserved_epic?(epics), do: is_list(epics) and Enum.any?(epics, &(is_map(&1) and &1[:key] == "unsorted"))

  defp relabel(epics, changes) when is_list(changes) do
    with :ok <- check(Enum.all?(changes, &epic?/1) and length(Enum.uniq_by(changes, & &1.key)) == length(changes), :invalid_epics) do
      keys = Enum.map(epics, & &1.key)

      case Enum.find(changes, &(&1.key not in keys)) do
        nil ->
          {:ok,
           Enum.map(epics, fn epic ->
             requested = Enum.find(changes, epic, &(&1.key == epic.key))
             merged = Map.merge(epic, requested)
             if Map.has_key?(requested, :hue) and not Map.has_key?(requested, :color), do: Map.delete(merged, :color), else: merged
           end)}

        epic ->
          {:error, {:unknown_epic, epic.key}}
      end
    end
  end

  defp relabel(_, _), do: {:error, :invalid_epics}

  defp epics?(epics) when is_list(epics) do
    icons = for %{icon: icon} <- epics, do: icon

    epics != [] and Enum.all?(epics, &epic?/1) and length(Enum.uniq_by(epics, & &1.key)) == length(epics) and
      length(Enum.uniq(icons)) == length(icons)
  end

  defp epics?(_), do: false
  defp matches?(value, regex), do: is_binary(value) and String.valid?(value) and Regex.match?(regex, value)
  defp check(true, _), do: :ok
  defp check(false, error), do: {:error, error}
  defp distance(a, b), do: min(abs(a - b), 360 - abs(a - b))
  defp default(nil, fallback), do: fallback
  defp default(value, _), do: value
  defp duplicate(keys), do: Enum.find(keys, fn key -> Enum.count(keys, &(&1 == key)) > 1 end)
end
