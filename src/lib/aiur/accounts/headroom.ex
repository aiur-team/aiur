defmodule Aiur.Accounts.Headroom do
  @moduledoc """
  Pure headroom ranking for `agent.account_selection: headroom` (#3960).

  Inputs are a list of candidates (already filtered by the caller's credential,
  pricing and availability gates, and ordered by `agent.priority`) and one
  usage reading per candidate. The output is the chosen candidate plus a score
  for every candidate, so a dispatch can say why it picked what it picked.

  This module reads no config, process state or files, so it can move with the
  provider-meter package.

  ## Score

  The score is the remaining fraction of the **binding window**: the window
  with the highest used percent (for Claude, the larger of the 5-hour and the
  weekly window; for Codex, the larger of its short and weekly windows).

  Candidates rank in tiers, then by remaining fraction, then by input order:

    1. known usage with more than 10% left;
    2. unknown usage (no reading). It is never shown as a number;
    3. known usage with 10% or less left;
    4. exhausted (a limited flag, or no usage left). Never chosen.
  """

  @low_headroom 0.10
  @tiers %{known: 0, unknown: 1, low: 2, exhausted: 3}

  @typedoc "One dispatch target. `:backend` and `:account` identify it; other keys are carried through."
  @type candidate :: %{required(:backend) => String.t(), required(:account) => String.t() | nil, optional(atom()) => term()}

  @typedoc """
  A usage reading. `:windows` maps a window name to its used percent (0..100).
  `limited: true` marks a candidate the caller already knows is refused.
  `nil` means no reading exists.
  """
  @type reading :: %{optional(:windows) => %{optional(String.t()) => number() | nil}, optional(:limited) => boolean(), optional(:source) => String.t()} | nil

  @type status :: :known | :low | :unknown | :exhausted

  @type scored :: %{
          candidate: candidate(),
          status: status(),
          remaining: float() | nil,
          binding_window: String.t() | nil,
          source: String.t() | nil,
          index: non_neg_integer()
        }

  @doc "Scores every candidate and returns them best first. Exhausted candidates sort last."
  @spec rank([candidate()], %{optional({String.t(), String.t() | nil}) => reading()}) :: [scored()]
  def rank(candidates, readings) when is_list(candidates) and is_map(readings) do
    candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, index} -> score(candidate, Map.get(readings, key(candidate)), index) end)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  Picks the candidate with the most headroom. Returns `{:ok, chosen, ranked}`,
  or `{:error, :all_exhausted, ranked}` when every candidate is exhausted (or
  there are none).
  """
  @spec select([candidate()], %{optional({String.t(), String.t() | nil}) => reading()}) ::
          {:ok, scored(), [scored()]} | {:error, :all_exhausted, [scored()]}
  def select(candidates, readings) do
    ranked = rank(candidates, readings)

    case ranked do
      [%{status: status} = chosen | _] when status != :exhausted -> {:ok, chosen, ranked}
      _ -> {:error, :all_exhausted, ranked}
    end
  end

  @doc "The reading key of a candidate: `{backend, account}`."
  @spec key(candidate()) :: {String.t(), String.t() | nil}
  def key(%{backend: backend, account: account}), do: {backend, account}

  @doc ~S"""
  Short label for one scored candidate, for logs and status lines, e.g.
  `claude/everdred=64%`, `codex=unknown`, `claude/default=exhausted`.
  """
  @spec label(scored()) :: String.t()
  def label(%{candidate: candidate} = scored), do: name(candidate) <> "=" <> value(scored)

  @doc "One line that names the choice and every alternative's score."
  @spec summary(scored() | nil, [scored()]) :: String.t()
  def summary(nil, ranked), do: "headroom: no candidate has usage left (" <> Enum.map_join(ranked, ", ", &label/1) <> ")"

  def summary(chosen, ranked) do
    alternatives = Enum.reject(ranked, &(&1.index == chosen.index))
    base = "headroom: " <> label(chosen)
    if alternatives == [], do: base, else: base <> "; alternatives " <> Enum.map_join(alternatives, ", ", &label/1)
  end

  @doc "Remaining percent (0..100) of a reading's binding window, or `nil` when the reading has no usage number."
  @spec remaining_percent(reading()) :: non_neg_integer() | nil
  def remaining_percent(reading) do
    case score(%{backend: "", account: nil}, reading, 0) do
      %{status: :exhausted} -> 0
      %{remaining: remaining} when is_float(remaining) -> round(remaining * 100)
      _unknown -> nil
    end
  end

  @doc "Display name of a candidate: `backend` or `backend/account`."
  @spec name(candidate()) :: String.t()
  def name(%{backend: backend, account: nil}), do: backend
  def name(%{backend: backend, account: account}), do: backend <> "/" <> account

  defp value(%{status: :exhausted}), do: "exhausted"
  defp value(%{status: :unknown}), do: "unknown"
  defp value(%{remaining: remaining}), do: "#{round(remaining * 100)}%"

  defp score(candidate, reading, index) do
    base = %{candidate: candidate, index: index, source: source(reading), binding_window: nil, remaining: nil}

    case binding_window(reading) do
      :limited -> Map.put(base, :status, :exhausted)
      nil -> Map.put(base, :status, :unknown)
      {window, used} -> classify(%{base | binding_window: window, remaining: remaining(used)})
    end
  end

  defp classify(%{remaining: remaining} = scored) when remaining <= 0.0, do: Map.merge(scored, %{status: :exhausted, remaining: 0.0})
  defp classify(%{remaining: remaining} = scored) when remaining <= @low_headroom, do: Map.put(scored, :status, :low)
  defp classify(scored), do: Map.put(scored, :status, :known)

  defp binding_window(%{limited: true}), do: :limited

  defp binding_window(%{windows: windows}) when is_map(windows) do
    windows
    |> Enum.filter(fn {_window, used} -> is_number(used) end)
    |> Enum.max_by(fn {_window, used} -> used end, fn -> nil end)
  end

  defp binding_window(_reading), do: nil

  defp remaining(used), do: (100 - min(max(used, 0), 100)) / 100

  defp source(%{source: source}) when is_binary(source), do: source
  defp source(_reading), do: nil

  defp sort_key(%{status: status, remaining: remaining, index: index}), do: {Map.fetch!(@tiers, status), -(remaining || 0.0), index}
end
