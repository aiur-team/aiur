defmodule Aiur.Opencode.WarmthReport do
  @moduledoc """
  Compute per-identifier wall-time deltas for the two ⚪-threshold rules:

    * **loose:** would have flipped to ⚪ on first attach
      (`attach_count >= 1`).
    * **strict:** flips to ⚪ when `attach_count >= visible_count + 1`.

  Built from `aiur_perf` event lines. Use `from_log_file/1` to read
  the active aiur log, `from_events/1` to feed an in-memory event list
  (used by tests and the e2e suite).

  The report is a list of rows:

      %{
        identifier: String.t(),
        t_first_attach_ms: pos_integer() | nil,
        t_strict_ms: pos_integer() | nil,
        loose_to_strict_delta_ms: integer() | :strict_never_reached
      }
  """

  @aiur_perf_re ~r/aiur_perf phase=(?<phase>\S+)\s+at_ms=(?<at_ms>\-?\d+)/

  @type event :: %{phase: atom(), at_ms: integer(), identifier: String.t() | nil}

  @doc """
  Build the warmth report from a list of events. Events are tuples
  `{phase, meta, at_ms}` or maps with `:phase`, `:meta`, `:at_ms`.

  Replays the event stream to compute attach_count + visible_count
  over time, then per identifier reports the t_first_attach and t_strict.
  """
  @spec from_events([event()]) :: [map()]
  def from_events(events) when is_list(events) do
    sorted = Enum.sort_by(events, & &1.at_ms)

    {first_attach, strict_at, _final_state} =
      Enum.reduce(sorted, {%{}, %{}, %{}}, fn ev, {first_attach, strict_at, state} ->
        new_state = apply_event(state, ev)

        first_attach =
          if ev.phase == :slot_attach_added and is_binary(ev.identifier) do
            Map.put_new(first_attach, ev.identifier, ev.at_ms)
          else
            first_attach
          end

        strict_at = update_strict_thresholds(strict_at, new_state, ev.at_ms)

        {first_attach, strict_at, new_state}
      end)

    first_attach
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      t_first = Map.get(first_attach, id)
      t_strict = Map.get(strict_at, id)

      delta =
        case {t_first, t_strict} do
          {nil, _} -> :no_attach
          {_, nil} -> :strict_never_reached
          {a, b} when is_integer(a) and is_integer(b) -> b - a
        end

      %{
        identifier: id,
        t_first_attach_ms: t_first,
        t_strict_ms: t_strict,
        loose_to_strict_delta_ms: delta
      }
    end)
  end

  @doc """
  Build the report by parsing `aiur_perf` lines from `path`.
  """
  @spec from_log_file(Path.t()) :: [map()]
  def from_log_file(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> parse_log() |> from_events()
      {:error, _} -> []
    end
  end

  @doc "Format the report rows as a printable string."
  @spec format([map()]) :: String.t()
  def format([]) do
    "warmth-report: no slot_attach_added events found\n"
  end

  def format(rows) do
    header =
      "identifier                    t_first_attach_ms  t_strict_ms  loose→strict_delta_ms"

    sep = String.duplicate("─", String.length(header))

    body =
      rows
      |> Enum.map_join("\n", fn r ->
        delta_str =
          case r.loose_to_strict_delta_ms do
            n when is_integer(n) -> "#{n}"
            other -> Atom.to_string(other)
          end

        :io_lib.format("~-30s ~-18s ~-12s ~-22s", [
          r.identifier,
          "#{r.t_first_attach_ms}",
          "#{r.t_strict_ms}",
          delta_str
        ])
        |> IO.iodata_to_binary()
      end)

    Enum.join([header, sep, body, ""], "\n")
  end

  # --- internals -----------------------------------------------------------

  defp apply_event(state, %{phase: :slot_attach_added, identifier: id, slot: slot})
       when is_binary(id) and is_integer(slot) do
    entry = Map.get(state, id, %{attached_slots: MapSet.new(), visible_in: nil})
    new_entry = %{entry | attached_slots: MapSet.put(entry.attached_slots, slot)}
    Map.put(state, id, new_entry)
  end

  defp apply_event(state, %{phase: :slot_attach_removed, identifier: id, slot: slot})
       when is_binary(id) and is_integer(slot) do
    case Map.get(state, id) do
      nil ->
        state

      entry ->
        new_entry = %{entry | attached_slots: MapSet.delete(entry.attached_slots, slot)}
        Map.put(state, id, new_entry)
    end
  end

  defp apply_event(state, %{phase: :slot_visible_changed, identifier: id, slot: slot})
       when is_binary(id) and is_integer(slot) do
    state =
      Enum.reduce(state, state, fn {other_id, other_entry}, acc ->
        if other_id != id and other_entry.visible_in == slot do
          Map.put(acc, other_id, %{other_entry | visible_in: nil})
        else
          acc
        end
      end)

    entry = Map.get(state, id, %{attached_slots: MapSet.new(), visible_in: nil})
    Map.put(state, id, %{entry | visible_in: slot})
  end

  defp apply_event(state, %{phase: :slot_visible_changed, identifier: nil, slot: slot})
       when is_integer(slot) do
    Enum.reduce(state, state, fn {id, entry}, acc ->
      if entry.visible_in == slot do
        Map.put(acc, id, %{entry | visible_in: nil})
      else
        acc
      end
    end)
  end

  defp apply_event(state, _other), do: state

  defp update_strict_thresholds(strict_at, state, at_ms) do
    visible_count =
      Enum.count(state, fn {_id, e} -> not is_nil(e.visible_in) end)

    Enum.reduce(state, strict_at, fn {id, entry}, acc ->
      attach_count = MapSet.size(entry.attached_slots)

      if attach_count >= visible_count + 1 and not Map.has_key?(acc, id) do
        Map.put(acc, id, at_ms)
      else
        acc
      end
    end)
  end

  defp parse_log(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    case Regex.named_captures(@aiur_perf_re, line) do
      nil ->
        []

      %{"phase" => phase, "at_ms" => at_ms} ->
        [
          %{
            phase: String.to_atom(phase),
            at_ms: String.to_integer(at_ms),
            identifier: extract_value(line, "identifier"),
            slot: extract_int(line, "slot")
          }
        ]
    end
  end

  defp extract_value(line, key) do
    case Regex.run(~r/\b#{key}=([^\s]+)/, line) do
      [_, val] -> val
      _ -> nil
    end
  end

  defp extract_int(line, key) do
    case extract_value(line, key) do
      nil -> nil
      val -> String.to_integer(val)
    end
  rescue
    _ -> nil
  end
end
