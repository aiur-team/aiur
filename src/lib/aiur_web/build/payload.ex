defmodule AiurWeb.Build.Payload do
  @moduledoc """
  Build board wire schema v1. Strings are raw data; scrub replaces invalid UTF-8.
  All fields defined by PayloadSchema are required unless explicitly optional.
  Unknown values are nil, never a fabricated zero. Unknown keys are rejected.

  Snapshot: v, kind, epoch, generation, now; writable, repo (url or nil), epics,
  features, order, counts (whole-index totals or nil), sections (hist/now/plan/nq),
  history (from/more/total/undated/tz), sources (history/features/queue/agents/index),
  usage (authorized/locked/unavailable), daemon (state/heartbeat_at/observed_at).
  Epic flags general/feature/temp/unsorted are optional. Feature to=nil means open.

  Rows: id, num, title, type, epic, feature, also, cx, pts, sec, ord, start, end,
  created, status, pct, agent, est, override, added, deps, wave, qpos, cue, pr.
  Id is a decimal ticket identifier or pack:<key>. Hist requires integer end;
  plan requires cue, others require cue=nil. Percentages are 0..100, cx is 1..5,
  wave is positive or nil. Agent model is a safe slug; effort is low/medium/high.
  Titles, labels and reasons remain unescaped; the client escapes on rendering.

  Diff: envelope plus upsert/remove/set. Set replaces whole blocks, never merges
  deeply; history_meta is translated to the socket's history block. Hist upserts
  before history.from are excluded. Earlier: envelope without now plus rows/history.
  Error: v/kind/reason (invalid_params/unavailable/read_only/not_found).

  Epoch identifies a LiveView process; generation advances once per diff, twice
  for an index restart. Snapshots do not increment it. Source index_generation
  is private and excluded from the wire. Locked usage contains only access copy.
  Additive fields land with their producer, schema and fixture; breaking meaning,
  removal or renaming bumps the version. No HTML is carried by board messages.
  """
  alias AiurWeb.Build.PayloadValidator
  @version 1
  @row_fields ~w(id num title type epic feature also cx pts sec ord start end created status pct agent est override added deps wave qpos cue pr)a

  @spec snapshot(map(), String.t(), non_neg_integer()) :: map()
  def snapshot(data, epoch, generation) do
    data |> scrub() |> Map.drop(["index_generation", "v", "kind", "epoch", "generation"]) |> Map.merge(envelope("snapshot", epoch, generation))
  end

  @spec diff(map(), String.t(), non_neg_integer(), map() | nil) :: map()
  def diff(changes, epoch, generation, history) do
    changes = scrub(changes)
    upsert = Enum.reject(changes["upsert"], &outside_window?(&1, history))
    set = history_set(changes["set"], history)
    envelope("diff", epoch, generation) |> Map.merge(%{"now" => changes["now"], "upsert" => upsert, "remove" => changes["remove"], "set" => set})
  end

  @spec earlier(map(), String.t(), non_neg_integer()) :: map()
  def earlier(page, epoch, generation), do: page |> scrub() |> Map.merge(envelope("earlier", epoch, generation))

  @spec error(atom()) :: map()
  def error(reason), do: %{"v" => @version, "kind" => "error", "reason" => Atom.to_string(reason)}

  @spec row(map()) :: {:ok, map()} | {:error, {:missing, atom() | String.t()}}
  def row(map) do
    Enum.reduce_while(@row_fields, {:ok, map}, fn key, acc ->
      if Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)), do: {:cont, acc}, else: {:halt, {:error, {:missing, missing_key(map, key)}}}
    end)
  end

  @spec validate(map()) :: :ok | {:error, [{String.t(), atom()}]}
  def validate(message) when is_map(message), do: message |> scrub() |> PayloadValidator.validate()
  def validate(_message), do: {:error, [{"", :type}]}

  @spec scrub(term()) :: term()
  def scrub(value) when is_binary(value), do: String.replace_invalid(value)
  def scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)
  def scrub(value) when is_map(value), do: Map.new(value, fn {key, child} -> {scrub_key(key), scrub(child)} end)
  def scrub(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  def scrub(value), do: value

  @spec bytes(map()) :: non_neg_integer()
  def bytes(message), do: IO.iodata_length(Jason.encode_to_iodata!(message))

  defp envelope(kind, epoch, generation), do: %{"v" => @version, "kind" => kind, "epoch" => epoch, "generation" => generation}
  defp scrub_key(key) when is_atom(key), do: Atom.to_string(key)
  defp scrub_key(key), do: scrub(key)
  defp missing_key(map, key), do: if(Enum.any?(Map.keys(map), &is_atom/1), do: key, else: Atom.to_string(key))
  defp outside_window?(%{"sec" => "hist", "end" => time}, %{"from" => from}) when is_integer(time) and is_integer(from), do: time < from
  defp outside_window?(_row, _history), do: false
  defp history_set(%{"history_meta" => meta} = set, history) when is_map(meta) and is_map(history), do: set |> Map.delete("history_meta") |> Map.put("history", Map.merge(history, meta))
  defp history_set(%{"history_meta" => meta} = set, nil) when is_map(meta), do: Map.delete(set, "history_meta")
  defp history_set(set, _history), do: set
end
