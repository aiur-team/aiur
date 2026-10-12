defmodule Aiur.BuildOrder.Features.FeatureData do
  @moduledoc false
  @hues [175, 55, 285, 128, 232, 18, 330, 80, 250, 150, 272]
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
  def epic?(%{key: key, label: label} = epic), do: map_size(epic) == 2 and epic_key?(key) and text?(label, 80)
  def epic?(_), do: false

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
        epics: default(input[:epics], [%{key: "f-" <> slug, label: input.label}]),
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
        nil -> {:ok, Enum.map(epics, fn epic -> Enum.find(changes, epic, &(&1.key == epic.key)) end)}
        epic -> {:error, {:unknown_epic, epic.key}}
      end
    end
  end

  defp relabel(_, _), do: {:error, :invalid_epics}
  defp epics?(epics), do: is_list(epics) and epics != [] and Enum.all?(epics, &epic?/1) and length(Enum.uniq_by(epics, & &1.key)) == length(epics)
  defp matches?(value, regex), do: is_binary(value) and String.valid?(value) and Regex.match?(regex, value)
  defp check(true, _), do: :ok
  defp check(false, error), do: {:error, error}
  defp distance(a, b), do: min(abs(a - b), 360 - abs(a - b))
  defp default(nil, fallback), do: fallback
  defp default(value, _), do: value
  defp duplicate(keys), do: Enum.find(keys, fn key -> Enum.count(keys, &(&1 == key)) > 1 end)
end
