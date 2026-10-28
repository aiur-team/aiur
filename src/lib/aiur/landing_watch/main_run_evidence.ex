defmodule Aiur.LandingWatch.MainRunEvidence do
  @moduledoc false

  alias Aiur.LandingWatch.RunnerDegradation

  @spec rows(map()) :: [map()]
  def rows(%{digest: %{checks: checks}} = entry) when is_list(checks) do
    for %{tests: tests} = check <- checks, is_list(tests), test <- tests, is_binary(test[:identity]) do
      %{
        "identity" => test.identity,
        "source" => "base",
        "run_url" => url(entry, check),
        "head_sha" => entry[:sha],
        "at_ms" => entry.completed_at,
        "path" => test[:path],
        "job" => check[:name],
        "excerpt" => "",
        "group_prs" => []
      }
    end
  end

  def rows(_entry), do: []

  @spec url(map(), map() | nil) :: String.t() | nil
  def url(entry, check), do: (check && check[:url]) || Enum.find_value(entry.digest.checks, & &1[:url]) || List.first(Map.get(entry, :run_urls, []))

  @spec run_id(String.t() | nil) :: pos_integer() | nil
  def run_id(url) when is_binary(url) do
    case Regex.run(~r{/runs/(\d+)}, url, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  def run_id(_url), do: nil

  @spec degraded?(map(), keyword()) :: boolean()
  def degraded?(entry, opts, jobs_fun) do
    case run_id(url(entry, nil)) do
      id when is_integer(id) ->
        case jobs_fun.(id, opts) do
          {:ok, jobs} -> RunnerDegradation.degraded?(jobs, opts)
          _ -> false
        end

      _ ->
        false
    end
  end
end
