defmodule Aiur.AllowedContributors.Ledger do
  @moduledoc """
  Restart-durable intake state: which issue numbers already received a
  terminal decision, each author's recent accepted wakes, and the last
  allow-list commit the operator was shown.

  The seen set is what makes "exactly one wake per issue" hold across both
  producers (webhook and poll) and across daemon restarts; entries older than
  seven days are pruned, and intake refuses any issue older than that horizon
  (`Intake`), so a pruned number can never be woken again. The accept
  timestamps keep the per-author hourly cap across restarts — a compromised
  allowed account must not get a fresh budget each time the daemon restarts.
  The remembered allow-list SHA is what makes the change alert fire once per
  merged change rather than once per boot.

  Persistence failures never crash the intake server: `save/2` reports them
  and the caller keeps its in-memory ledger authoritative for the rest of the
  process lifetime.
  """

  require Logger

  alias Aiur.JsonStore

  @retention_ms 7 * 24 * 3_600_000

  @type t :: %{
          seen: %{optional(String.t()) => integer()},
          rate: %{optional(pos_integer()) => [integer()]},
          sha: String.t() | nil,
          entries: [String.t()]
        }

  @doc "Milliseconds a seen issue number is remembered; also intake's age horizon."
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  @spec load(Path.t()) :: t()
  def load(path) do
    case JsonStore.read(path, nil) do
      {:ok, %{"seen" => seen} = data} when is_map(seen) ->
        %{
          seen: Map.filter(seen, fn {key, at} -> is_binary(key) and is_integer(at) end),
          rate: decode_rate(data["rate"]),
          sha: string_or_nil(data["sha"]),
          entries: Enum.filter(List.wrap(data["entries"]), &is_binary/1)
        }

      {:ok, nil} ->
        empty()

      other ->
        Logger.error("allowed_contributors ledger_unreadable path=#{path} result=#{inspect(other)}; starting empty")
        empty()
    end
  end

  @spec seen?(t(), pos_integer()) :: boolean()
  def seen?(ledger, number), do: Map.has_key?(ledger.seen, Integer.to_string(number))

  @spec mark_seen(t(), pos_integer(), integer()) :: t()
  def mark_seen(ledger, number, now_ms) do
    seen =
      ledger.seen
      |> Map.filter(fn {_number, at} -> now_ms - at < @retention_ms end)
      |> Map.put(Integer.to_string(number), now_ms)

    %{ledger | seen: seen}
  end

  @spec put_rate(t(), %{optional(pos_integer()) => [integer()]}) :: t()
  def put_rate(ledger, rate), do: %{ledger | rate: rate}

  @spec put_allowlist(t(), String.t() | nil, [String.t()]) :: t()
  def put_allowlist(ledger, sha, entries), do: %{ledger | sha: sha, entries: entries}

  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(ledger, path) do
    File.mkdir_p!(Path.dirname(path))

    JsonStore.write!(path, %{
      "seen" => ledger.seen,
      "rate" => Map.new(ledger.rate, fn {author, stamps} -> {Integer.to_string(author), stamps} end),
      "sha" => ledger.sha,
      "entries" => ledger.entries
    })
  rescue
    error ->
      Logger.error("allowed_contributors ledger_write_failed path=#{path} error=#{Exception.message(error)}")
      {:error, error}
  end

  defp empty, do: %{seen: %{}, rate: %{}, sha: nil, entries: []}

  defp decode_rate(rate) when is_map(rate) do
    for {author, stamps} <- rate,
        {id, ""} <- [Integer.parse(to_string(author))],
        id > 0,
        is_list(stamps),
        into: %{},
        do: {id, Enum.filter(stamps, &is_integer/1)}
  end

  defp decode_rate(_rate), do: %{}

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end
