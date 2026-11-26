defmodule VoiceConverse.SessionLimits do
  @moduledoc false

  alias VoiceConverse.{Config, TranscriptIndex}

  @spec under_daily_cap?(Config.t(), keyword()) :: :ok | {:error, :cost_cap | :unknown}
  def under_daily_cap?(config, opts \\ [])

  def under_daily_cap?(%Config{limits: %{daily_minutes_cap: nil}}, _opts), do: :ok
  def under_daily_cap?(%Config{limits: %{daily_minutes_cap: 0}}, _opts), do: reached()
  def under_daily_cap?(%Config{transcript: :none}, _opts), do: :ok

  def under_daily_cap?(%Config{transcript_root: root, limits: %{daily_minutes_cap: cap}}, opts) do
    case TranscriptIndex.minutes_today(root, opts) do
      minutes when is_integer(minutes) and minutes < cap -> :ok
      minutes when is_integer(minutes) -> reached()
      _ -> {:error, :unknown}
    end
  end

  defp reached do
    :telemetry.execute([:voice_converse, :cost_cap, :reached], %{count: 1}, %{})
    {:error, :cost_cap}
  end
end
