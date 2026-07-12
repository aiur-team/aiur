defmodule Aiur.DecisionMetrics.Log do
  @moduledoc "Append/replay helpers for the best-effort Decision metrics stream."

  require Logger

  alias Aiur.DecisionMetrics.Sample

  @doc "Appends one redacted lifecycle snapshot without affecting Decision correctness."
  @spec append(Path.t(), Sample.t(), map(), DateTime.t()) :: :ok
  def append(path, sample, fact, observed_at) do
    payload =
      sample
      |> Sample.to_map()
      |> Map.merge(%{
        observed_at: DateTime.to_iso8601(observed_at),
        observed_event_id: fact.event_id,
        stage: Atom.to_string(fact.stage)
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload) <> "\n", [:append])
  rescue
    error ->
      Logger.error("decision_metrics write_failed issue_identifier=#{sample.identifier} decision_id=#{fact.decision_id} stage=#{fact.stage} error=#{inspect(error)}")

      :ok
  end

  @doc "Replays latest snapshots and observed IDs, tolerating malformed metric lines."
  @spec replay(Path.t()) :: {%{String.t() => Sample.t()}, MapSet.t(String.t())}
  def replay(path) do
    path
    |> read_lines()
    |> Enum.reduce({%{}, MapSet.new()}, fn line, {samples, seen} ->
      with {:ok, decoded} <- Jason.decode(line),
           {:ok, sample} <- Sample.from_map(decoded),
           event_id when is_binary(event_id) <- decoded["observed_event_id"] do
        {Map.put(samples, sample.decision_id, sample), MapSet.put(seen, event_id)}
      else
        _other -> {samples, seen}
      end
    end)
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        String.split(contents, "\n", trim: true)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("decision_metrics replay_failed path=#{path} reason=#{inspect(reason)}")
        []
    end
  end
end
