defmodule Aiur.LandingWatch.DisjointFailureCache do
  @moduledoc false

  alias Aiur.LandingWatch.PrRerunClassifier

  @spec run([map()], keyword(), (map(), keyword() -> term())) :: term()
  def run(observations, opts, process_observation) when is_function(process_observation, 2) do
    opts = Keyword.put(opts, :all_observations, observations)
    key = {__MODULE__, make_ref()}

    cached_opts =
      Keyword.put(opts, :disjoint_failure_prs_fun, fn ->
        case Process.get(key, :missing) do
          :missing ->
            result = PrRerunClassifier.disjoint_failure_prs(observations, opts)
            Process.put(key, result)
            result

          result ->
            result
        end
      end)

    try do
      reduce(observations, cached_opts, process_observation)
    after
      Process.delete(key)
    end
  end

  defp reduce(observations, opts, process_observation) do
    Enum.reduce(observations, :ok, fn observation, first_error ->
      result = process_observation.(observation, opts)
      if first_error == :ok, do: result, else: first_error
    end)
  end
end
