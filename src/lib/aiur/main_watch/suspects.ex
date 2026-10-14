defmodule Aiur.MainWatch.Suspects do
  @moduledoc false
  alias Aiur.GitHub.Transport

  @spec fetch(String.t() | nil, String.t(), [String.t()], [map()], keyword()) :: map()
  def fetch(green, red, commits, early, opts) do
    since_red = Enum.drop_while(commits, &(&1 != red))
    range = Enum.take_while(since_red, &(&1 != green))
    complete = is_binary(green) and green in since_red

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

      results = Enum.map(range, &fetch_commit(owner, repo, &1, early, token, request))

      prs =
        Enum.flat_map(results, fn
          {:ok, prs} -> prs
          _ -> []
        end)
        |> Enum.uniq_by(& &1.number)

      %{pull_requests: prs, complete: complete and Enum.all?(results, &match?({:ok, _}, &1))}
    else
      {:error, reason} -> %{pull_requests: [], complete: false, error: inspect(reason)}
    end
  end

  defp fetch_commit(owner, repo, sha, early, token, request) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/commits/#{URI.encode_www_form(sha)}/pulls?per_page=100"

    case Transport.fetch_json_list(request, token, url, caller: "main_watch_suspects") do
      {:ok, prs} -> {:ok, prs |> Enum.filter(&is_binary(&1["merged_at"])) |> Enum.map(&merge(&1, sha, early))}
      error -> error
    end
  end

  defp merge(pr, sha, early) do
    record = Enum.find(early, &(value(&1, :sha) == sha or value(&1, :pr) == pr["number"]))
    pending = if record, do: value(record, :pending_checks)
    %{number: pr["number"], url: pr["html_url"], sha: sha, early: if(is_list(pending), do: pending != [], else: :unknown)}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
