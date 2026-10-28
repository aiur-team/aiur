defmodule Aiur.VoiceConversation.SessionComparison do
  @moduledoc false
  alias Aiur.VoiceConversation.Comparison

  @spec prepare(keyword()) :: {:ok, map() | nil, keyword()} | {:error, term()}
  def prepare(opts) do
    case Keyword.get(opts, :comparison) do
      nil -> {:ok, nil, opts}
      spec -> reserve(spec, opts)
    end
  end

  defp reserve(spec, opts) do
    with {:ok, row} <- Comparison.reserve(spec.root, spec.provider, spec.model, spec.max_seconds) do
      clock = Map.get(spec, :clock, fn -> System.monotonic_time(:millisecond) end)
      comparison = %{root: spec.root, token: row["id"], started: clock.(), clock: clock, first_audio_ms: nil, reserved_seconds: row["reserved_seconds"]}
      {:ok, comparison, Keyword.put(opts, :max_session_seconds, row["reserved_seconds"])}
    end
  end

  @spec audio(map() | nil) :: map() | nil
  def audio(%{first_audio_ms: nil} = comparison), do: %{comparison | first_audio_ms: elapsed(comparison)}
  def audio(comparison), do: comparison

  @spec schedule(map() | nil) :: reference() | nil
  def schedule(nil), do: nil
  def schedule(comparison), do: Process.send_after(self(), :comparison_cap, max(0, comparison.reserved_seconds * 1_000 - elapsed(comparison)))

  @spec finish(map() | nil, String.t(), pid()) :: :ok
  def finish(nil, _id, _owner), do: :ok

  def finish(comparison, id, owner) do
    case Comparison.finish(comparison.root, comparison.token, id, elapsed(comparison), comparison.first_audio_ms) do
      :ok -> send(owner, {:executor_voice, {:comparison_saved, comparison.token}})
      _error -> send(owner, {:executor_voice, {:error, :comparison_unavailable, "Comparison could not be saved; reserved minutes remain charged."}})
    end

    :ok
  end

  defp elapsed(comparison), do: max(0, comparison.clock.() - comparison.started)
end
