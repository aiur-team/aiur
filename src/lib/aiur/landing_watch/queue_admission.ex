defmodule Aiur.LandingWatch.QueueAdmission do
  @moduledoc false

  alias Aiur.LandingWatch.{Attribution, ConflictRouting, LocalRead, Observer}

  @spec run(map(), keyword(), function(), function()) :: term()
  def run(observation, opts, enqueue, route_rework) do
    revalidate = Keyword.get(opts, :revalidate_fun, &Observer.revalidate_approved_head/3)
    attribution = Keyword.get(opts, :attribution_fun, &default_attribution(&1, opts))

    case LocalRead.run(revalidate, [observation.number, observation.head, opts], opts) do
      :ok ->
        case LocalRead.run(attribution, [observation], opts) do
          {:ok, :clean} -> enqueue.(observation, opts)
          {:ok, {:ai_attribution, detail}} -> route_rework.(observation, [%{name: "AI commit attribution", excerpt: detail}], opts)
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_attribution_result}
        end

      {:hold, _reason} ->
        :ok

      {:error, :merge_conflict} ->
        ConflictRouting.route(observation, route_rework, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_attribution(observation, opts), do: Attribution.pull_request_clean?(observation.number, opts)
end
