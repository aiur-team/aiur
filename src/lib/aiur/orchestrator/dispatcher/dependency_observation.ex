defmodule Aiur.Orchestrator.Dispatcher.DependencyObservation do
  @moduledoc false
  require Logger

  alias Aiur.Orchestrator.{HoldDecline, State}
  alias Aiur.Tracker

  @spec observe((Aiur.Issue.t() -> term()), Aiur.Issue.t(), keyword()) :: term()
  def observe(hydrator, issue, opts) do
    case fetch(hydrator, issue, opts, 3) do
      {:error, reason} ->
        Logger.warning("Starting candidate after bounded GitHub dependency observation failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")
        {:ok, issue}

      result ->
        HoldDecline.observe(result)
    end
  end

  defp fetch(_hydrator, _issue, _opts, 0), do: {:error, :observation_attempts_exhausted}

  defp fetch(hydrator, issue, opts, remaining) do
    case Tracker.with_transient_retry(fn -> hydrator.(issue) end, opts) do
      {:error, _reason} when remaining > 1 -> fetch(hydrator, issue, opts, remaining - 1)
      result -> result
    end
  end
end
