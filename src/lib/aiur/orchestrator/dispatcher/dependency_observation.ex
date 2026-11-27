defmodule Aiur.Orchestrator.Dispatcher.DependencyObservation do
  @moduledoc false
  require Logger

  alias Aiur.Orchestrator.{HoldDecline, State}
  alias Aiur.Tracker

  @spec observe((Aiur.Issue.t() -> term()), Aiur.Issue.t(), keyword()) :: term()
  def observe(hydrator, issue, opts) do
    case fetch(hydrator, issue, opts, 3) do
      {:bounded_observation_exhausted, reason} ->
        Logger.warning("Starting candidate after bounded GitHub dependency observation failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")
        {:ok, issue}

      result ->
        HoldDecline.observe(result)
    end
  end

  defp fetch(hydrator, issue, opts, remaining) when remaining in 1..3 do
    case Tracker.with_transient_retry(fn -> hydrator.(issue) end, opts) do
      {:error, {:github, kind, _detail}} = result when kind in [:http, :local_hold, :auth, :permission] -> result
      {:error, {:aiur, :locally_held, _hold}} = result -> result
      {:error, _reason} when remaining > 1 -> fetch(hydrator, issue, opts, remaining - 1)
      {:error, reason} -> {:bounded_observation_exhausted, reason}
      result -> result
    end
  end
end
