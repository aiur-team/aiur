defmodule AiurWeb.Build.NowRows do
  @moduledoc """
  Pure projection of a Units catalog into agent-owned Now-band facts.
  Finished, replacement, unjoinable and other-repository rows are excluded;
  live, retrying and lifetime-latched rows remain, without a cap.

  State precedence (first match wins):

  | Units condition | State |
  | --- | --- |
  | Error work state, retrying bucket, or UnitsPolicy stuck | error |
  | Lifetime dispatch latch spent | retries |
  | Positive integer command count or waiting for human | command |
  | Paused with a non-reserving reason or GitHub budget hold | parked |
  | UnitsPolicy paused | paused |
  | Live and starting, allocated or working | active |
  | Anything else | nil |

  Unknown model, state, effort, progress and session start remain nil.
  Source freshness comes from this same catalog, never a separate clock or probe.
  """
  alias Aiur.BuildOrder.ProgressRenderer
  alias Aiur.Orchestrator.State
  alias Aiur.Projections.UnitsPolicy
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsPresentation

  @type now_facts :: %{
          id: String.t(),
          num: pos_integer(),
          sec: String.t(),
          status: String.t(),
          ord: integer(),
          start: integer() | nil,
          start_src: String.t(),
          pct: 0..100 | nil,
          agent: %{model: String.t() | nil, name: String.t() | nil, state: String.t() | nil, effort: String.t() | nil}
        }
  @type source_block :: %{state: String.t(), observed_at: integer() | nil, reason: String.t() | nil}

  @spec build(term(), keyword()) :: %{rows: %{String.t() => now_facts()}, source: source_block()}
  def build(catalog, opts \\ []) do
    case repository(Keyword.get(opts, :repository)) do
      nil -> unavailable("repository_unknown")
      repo -> project(catalog, repo)
    end
  end

  defp project(%{status: status, snapshot: %{rows: rows} = snapshot} = catalog, repo) when status in [:ready, :empty, :stale] and is_list(rows) do
    source = %{
      state: if(status == :stale, do: "stale", else: "ok"),
      observed_at: timestamp(get_in(snapshot, [:freshness, :status]) |> observed_at()),
      reason:
        cond do
          status == :stale -> "fleet_stale"
          catalog[:truncated?] == true -> "membership_truncated"
          true -> nil
        end
    }

    %{rows: rows |> Enum.filter(&band?(&1, repo)) |> Map.new(&{&1.identity.identifier, facts(&1)}), source: source}
  end

  defp project(_catalog, _repo), do: unavailable("fleet_unavailable")
  defp unavailable(reason), do: %{rows: %{}, source: %{state: "unavailable", observed_at: nil, reason: reason}}
  defp observed_at(%{observed_at: time}), do: time
  defp observed_at(_freshness), do: nil

  defp repository({owner, repo}) when is_binary(owner) and is_binary(repo) do
    parts = Enum.map([owner, repo], &String.trim/1)
    if Enum.all?(parts, &(&1 != "" and not String.contains?(&1, "/"))), do: Enum.map(parts, &String.downcase/1), else: nil
  end

  defp repository(_repo), do: nil

  defp band?(%{identity: identity} = row, repo) do
    TrackerIdentity.joinable?(identity) and repository({identity.owner, identity.repository}) == repo and
      not UnitsPolicy.condition?(:finished, row) and row[:replacement_boundary?] != true and
      (UnitsPolicy.in_scope?(row, :live) or get_in(row, [:runtime, :bucket]) == :retrying or get_in(row, [:reasons, :waiting]) == :latched_lifetime)
  end

  defp band?(_row, _repo), do: false

  defp facts(row) do
    num = String.to_integer(row.identity.identifier)
    family = UnitsPresentation.agent_family(row)

    start = timestamp(get_in(row, [:timestamps, :started_at]))

    %{
      id: row.identity.identifier,
      num: num,
      sec: "now",
      status: "running",
      ord: num,
      start: start,
      # The session start is the agent's dispatch; an unknown start has an unknown source (MP-E8-C4-T04).
      start_src: if(start, do: "dispatch", else: "unknown"),
      pct: pct(row),
      agent: %{model: model(family), name: UnitsPresentation.agent_label(family), state: agent_state(row), effort: effort(row[:effort])}
    }
  end

  defp agent_state(row) do
    work_state = get_in(row, [:runtime, :work_state])
    waiting = get_in(row, [:reasons, :waiting])
    pause = get_in(row, [:reasons, :pause])
    paused? = UnitsPolicy.condition?(:paused, row)

    cond do
      error?(row) -> "error"
      waiting == :latched_lifetime -> "retries"
      command?(row[:open_command_count], waiting) -> "command"
      parked?(paused?, pause) -> "parked"
      paused? -> "paused"
      UnitsPolicy.in_scope?(row, :live) and work_state in [:starting, :allocated, :working] -> "active"
      true -> nil
    end
  end

  defp error?(row), do: get_in(row, [:runtime, :work_state]) == :error or get_in(row, [:runtime, :bucket]) == :retrying or UnitsPolicy.condition?(:stuck, row)
  defp command?(count, waiting), do: (is_integer(count) and count > 0) or waiting == :waiting_for_human
  defp parked?(paused?, pause), do: paused? and (State.non_reserving_pause_reason?(pause) or pause == :github_budget_hold)

  defp model(family) when is_atom(family) and not is_nil(family) do
    key = Atom.to_string(family)
    if Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,31}$/, key), do: key, else: nil
  end

  defp model(_family), do: nil
  defp effort(value) when is_atom(value), do: effort(Atom.to_string(value))
  defp effort(value) when value in ~w(none minimal low medium high xhigh max), do: value
  defp effort(_value), do: nil
  # The Units reading becomes the RootSummary progress contract and is rendered
  # by ProgressRenderer; an unknown or out-of-range reading stays unknown (nil).
  defp pct(row), do: row |> progress_contract() |> ProgressRenderer.json() |> Map.fetch!("progress")

  defp progress_contract(%{progress: %{status: :known, percent: value}}) when is_number(value) and value >= 0 and value <= 100,
    do: %{progress: round(value), progress_resolution: :resolved}

  defp progress_contract(_row), do: %{progress: nil, progress_resolution: :unknown}
  defp timestamp(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)

  defp timestamp(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, time, _offset} -> timestamp(time)
      _ -> nil
    end
  end

  defp timestamp(_time), do: nil
end
