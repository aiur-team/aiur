defmodule Aiur.GitHub.HoldSweep do
  @moduledoc """
  Removes and alerts on quota hold files whose deadline is implausibly far ahead.

  A primary window resets within an hour and a secondary limit lasts minutes, so
  a hold more than an hour out is corrupt — a skewed clock or a test fixture
  wrote it — and would otherwise park every agent until it expires (#4698). The
  `gh` guard already ignores such holds; the daemon removes them and says so.
  """

  # One hour plus a minute of slack for a primary reset sampled at window start;
  # matches `hold_max_ahead` in `priv/github_guard/gh/55-holds.sh`.
  @max_ahead_seconds 3_660

  # A writer that keeps rewriting a bad hold would otherwise alert on every
  # sweep (#4714): each hold file alerts at most once per hour, though every
  # sweep still removes it.
  @realert_seconds 3_600

  @typedoc "Unix second each hold file last alerted, threaded through successive sweeps."
  @type alerted :: %{String.t() => integer()}

  @spec sweep(Path.t() | nil, DateTime.t(), (String.t(), keyword() -> term()), alerted()) :: alerted()
  def sweep(dir, now, emit_fun, alerted \\ %{})
  def sweep(nil, _now, _emit_fun, alerted), do: alerted

  def sweep(dir, now, emit_fun, alerted) do
    now = DateTime.to_unix(now)
    dir |> Path.join("*-hold") |> Path.wildcard() |> Enum.reduce(alerted, &sweep_file(&1, now, emit_fun, &2))
  end

  defp sweep_file(path, now, emit_fun, alerted) do
    name = Path.basename(path)

    with {:ok, contents} <- File.read(path),
         {until, ""} when until > now + @max_ahead_seconds <- Integer.parse(String.trim(contents)) do
      _ = File.rm(path)

      case alerted do
        %{^name => at} when now - at < @realert_seconds ->
          alerted

        _ ->
          message = "Removed implausible GitHub hold #{name} until #{until} (more than #{@max_ahead_seconds}s ahead)"
          emit_fun.("system.github.quota.implausible_hold", message: message, reason: message, severity: "warning", needs_attention: true)
          Map.put(alerted, name, now)
      end
    else
      _ -> alerted
    end
  end
end
