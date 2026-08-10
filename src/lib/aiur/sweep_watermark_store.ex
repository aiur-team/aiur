defmodule Aiur.SweepWatermarkStore do
  @moduledoc """
  Durable cursors for the GitHub reconciliation sweep.

  The firehose and comment pollers already track where they last read
  (`events_last_id`, per-target comment `since`, per-target review-seen
  timestamps), but those cursors lived only in `Aiur.Orchestrator.State` and
  reset on every restart. With no cursor to compare against, both pollers fall
  back to `Aiur.Events.GithubKeys.boot_cutoff_iso8601/1` — "everything since
  this boot" — so anything that happened while the daemon was down is
  indistinguishable from nothing having happened at all. Restarts are routine
  here, which makes that gap routine too.

  This store persists the cursors across restarts so the sweep can reason about
  what it last *saw* rather than re-reading the present.

  ## Cursors versus the cutoff

  Restored cursors do most of the work. The comment poller keys `since` per
  target, so a restored cursor already reopens the window for a ticket polled
  before the restart, and the review-submission poller inherits the same
  recovery through `pr_review_seen_at`.

  The firehose needs one thing more. `Aiur.Events.GithubFirehose` trims by
  `events_last_id`, but then drops anything created before this boot so an
  Executor restart cannot replay a day of Events API history into live agents.
  That drop is what makes a daemon-down event unrecoverable, so
  `restored_cutoff/2` supplies the last successful sweep time as the firehose's
  `:boot_time` instead. The window becomes "since we last actually looked",
  which is both a correct recovery boundary and still a bound.

  `observed_at` is therefore specifically the last successful firehose sweep.

  ## The lookback bound

  `restored_cutoff/2` never reaches further back than `max_lookback_seconds`
  (default 24h). GitHub's Events API only retains about a day anyway, and an
  unbounded lookback would let a daemon that was down for a week replay a week
  of history. When the recorded sweep is older than the bound the sweep still
  runs, but it covers less than the outage — `lookback_truncated?/2` reports
  that so it can be said out loud rather than assumed away.

  Missing, unreadable, or malformed state fails safe by returning no cursors,
  which restores exactly the pre-existing boot-cutoff behavior.
  """

  require Logger

  alias Aiur.Config.Paths
  alias Aiur.JsonStore

  @default_max_lookback_seconds 24 * 60 * 60

  @type cursors :: %{optional(String.t()) => String.t()}
  @type t :: %{
          events_last_id: String.t() | nil,
          comment_cursors: cursors(),
          pr_review_seen_at: cursors(),
          observed_at: DateTime.t() | nil
        }

  @doc """
  Loads the persisted sweep cursors, or an empty watermark when none exist.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    path = path_for(opts)

    case JsonStore.read(path, %{}) do
      {:ok, %{} = persisted} ->
        %{
          events_last_id: normalize_id(Map.get(persisted, "events_last_id")),
          comment_cursors: normalize_cursors(Map.get(persisted, "comment_cursors")),
          pr_review_seen_at: normalize_cursors(Map.get(persisted, "pr_review_seen_at")),
          observed_at: normalize_timestamp(Map.get(persisted, "observed_at"))
        }

      {:ok, _other} ->
        Logger.warning("Sweep watermark store at #{path} has an unexpected shape; sweeping from this boot instead")
        empty()

      {:error, reason} ->
        Logger.warning("Sweep watermark store at #{path} could not be read: #{inspect(reason)}; sweeping from this boot instead")
        empty()
    end
  end

  @doc """
  Persists the sweep cursors.

  Best-effort: a write failure must never interrupt a sweep that already
  published its events. The next sweep simply reconciles a wider window.
  """
  @spec save(t(), keyword()) :: :ok
  def save(%{} = watermark, opts \\ []) do
    path = path_for(opts)

    JsonStore.write!(path, %{
      "events_last_id" => normalize_id(Map.get(watermark, :events_last_id)),
      "comment_cursors" => normalize_cursors(Map.get(watermark, :comment_cursors)),
      "pr_review_seen_at" => normalize_cursors(Map.get(watermark, :pr_review_seen_at)),
      "observed_at" => encode_timestamp(Map.get(watermark, :observed_at))
    })

    :ok
  rescue
    error ->
      Logger.warning("Sweep watermark persistence failed at #{path_for(opts)}: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Returns the sweep cutoff to resume from, clamped to the lookback bound, or
  `nil` when no prior sweep is on record and the caller should keep today's
  boot-cutoff behavior.

  Callers hand the result to the firehose as `:boot_time`; `GithubKeys`
  subtracts its own overlap buffer on top, so an event created moments before
  the previous sweep finished is still recovered rather than trimmed at the
  boundary.
  """
  @spec restored_cutoff(t(), keyword()) :: DateTime.t() | nil
  def restored_cutoff(watermark, opts \\ [])

  def restored_cutoff(%{observed_at: %DateTime{} = observed_at}, opts) do
    floor = DateTime.add(now(opts), -max_lookback_seconds(opts), :second)

    if DateTime.compare(observed_at, floor) == :lt, do: floor, else: observed_at
  end

  def restored_cutoff(_watermark, _opts), do: nil

  @doc """
  True when the recorded sweep is older than the lookback bound, meaning the
  restored window no longer covers the whole gap since the last sweep.
  """
  @spec lookback_truncated?(t(), keyword()) :: boolean()
  def lookback_truncated?(watermark, opts \\ [])

  def lookback_truncated?(%{observed_at: %DateTime{} = observed_at}, opts) do
    floor = DateTime.add(now(opts), -max_lookback_seconds(opts), :second)

    DateTime.compare(observed_at, floor) == :lt
  end

  def lookback_truncated?(_watermark, _opts), do: false

  @doc false
  @spec empty() :: t()
  def empty,
    do: %{events_last_id: nil, comment_cursors: %{}, pr_review_seen_at: %{}, observed_at: nil}

  @doc false
  @spec path_for(keyword()) :: Path.t()
  def path_for(opts \\ []) do
    Keyword.get(opts, :sweep_watermark_path) ||
      Application.get_env(:aiur, :sweep_watermark_store_path) ||
      Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.sweep-watermark.json")
  end

  defp now(opts), do: Keyword.get(opts, :now) || DateTime.utc_now()

  defp max_lookback_seconds(opts) do
    case Keyword.get(opts, :max_lookback_seconds, Application.get_env(:aiur, :sweep_max_lookback_seconds)) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _other -> @default_max_lookback_seconds
    end
  end

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_id), do: nil

  defp normalize_cursors(cursors) when is_map(cursors) do
    Enum.reduce(cursors, %{}, fn
      {target, cursor}, acc when is_binary(target) and target != "" and is_binary(cursor) and cursor != "" ->
        Map.put(acc, target, cursor)

      _entry, acc ->
        acc
    end)
  end

  defp normalize_cursors(_cursors), do: %{}

  defp encode_timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_timestamp(_value), do: nil

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp normalize_timestamp(_value), do: nil
end
