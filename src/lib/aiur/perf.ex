defmodule Aiur.Perf do
  @moduledoc """
  Always-on structured perf logger for the pane-open hot path and
  opencode lifecycle. Emits `aiur_perf phase=<x>` lines that can be
  grep'd out of `log/aiur.log` and diffed across runs to measure
  before/after timings for any change that affects perceived load.

  Not gated on `--debug`. The same events drive the debug-mode footer
  in the agent list pane (see `Aiur.AgentList.App`).

  ## Line shape

      aiur_perf phase=<phase> at_ms=<monotonic_ms> elapsed_ms=<from_boot>
        [wall_ms=<duration>] [slot=<N>] [identifier=<id>] [pane_id=<%X>]
        [note=<text>] [key=value ...]

  - `at_ms` — monotonic milliseconds (stable, useful for diffing
    events within the same run).
  - `elapsed_ms` — milliseconds since BEAM boot via `Aiur.Boot`.
  - `wall_ms` — duration of the operation, when the caller measured it.

  ## API

      Perf.event(:placeholder_visible, slot: 1, identifier: "10", wall_ms: 42)
      span = Perf.span_begin(:serve_restart, slot: 1, identifier: "10")
      ...
      Perf.span_end(span)

  `span_begin/2` returns an opaque `{phase, started_at, meta}` tuple
  which `span_end/1` reads to compute `wall_ms`. Use it whenever the
  duration of an operation is meaningful.
  """

  require Logger
  alias Aiur.Boot

  @type phase :: atom()
  @type meta :: keyword()
  @opaque span :: {phase(), integer(), meta()}

  @perf_topic "aiur:perf"

  @doc "PubSub topic on which Aiur.Perf broadcasts every event."
  @spec topic() :: String.t()
  def topic, do: @perf_topic

  @spec event(phase(), meta()) :: :ok
  def event(phase, meta \\ []) when is_atom(phase) and is_list(meta) do
    Logger.info(format_line(phase, meta))
    broadcast_event(phase, meta)
    :ok
  end

  defp broadcast_event(phase, meta) do
    Phoenix.PubSub.broadcast(
      Aiur.PubSub,
      @perf_topic,
      {:aiur_perf,
       %{
         phase: phase,
         meta: Enum.into(meta, %{}),
         at_ms: System.monotonic_time(:millisecond),
         elapsed_ms: Boot.elapsed_ms()
       }}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @spec span_begin(phase(), meta()) :: span()
  def span_begin(phase, meta \\ []) when is_atom(phase) and is_list(meta) do
    now = System.monotonic_time(:millisecond)
    event(:"#{phase}_start", meta)
    {phase, now, meta}
  end

  @spec span_end(span(), meta()) :: :ok
  def span_end({phase, started_at, begin_meta}, extra_meta \\ []) do
    wall_ms = System.monotonic_time(:millisecond) - started_at
    merged = Keyword.merge(begin_meta, extra_meta) |> Keyword.put(:wall_ms, wall_ms)
    event(:"#{phase}_done", merged)
  end

  defp format_line(phase, meta) do
    now_ms = System.monotonic_time(:millisecond)
    elapsed = Boot.elapsed_ms()

    base = "aiur_perf phase=#{phase} at_ms=#{now_ms} elapsed_ms=#{elapsed}"

    extras = Enum.map_join(meta, " ", fn {k, v} -> "#{k}=#{format_value(v)}" end)

    if extras == "" do
      base
    else
      base <> " " <> extras
    end
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v), do: inspect(v)
end
