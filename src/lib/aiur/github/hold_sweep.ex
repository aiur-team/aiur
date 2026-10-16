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

  @spec sweep(Path.t() | nil, DateTime.t(), (String.t(), keyword() -> term())) :: :ok
  def sweep(nil, _now, _emit_fun), do: :ok

  def sweep(dir, now, emit_fun) do
    limit = DateTime.to_unix(now) + @max_ahead_seconds
    dir |> Path.join("*-hold") |> Path.wildcard() |> Enum.each(&sweep_file(&1, limit, emit_fun))
  end

  defp sweep_file(path, limit, emit_fun) do
    with {:ok, contents} <- File.read(path),
         {until, ""} when until > limit <- Integer.parse(String.trim(contents)) do
      _ = File.rm(path)
      message = "Removed implausible GitHub hold #{Path.basename(path)} until #{until} (more than #{@max_ahead_seconds}s ahead)"
      emit_fun.("system.github.quota.implausible_hold", message: message, reason: message, severity: "warning", needs_attention: true)
    end
  end
end
