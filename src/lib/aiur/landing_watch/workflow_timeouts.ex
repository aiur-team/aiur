defmodule Aiur.LandingWatch.WorkflowTimeouts do
  @moduledoc false

  alias Aiur.GitHub.Transport

  @spec for_jobs(map(), [map()], keyword()) :: %{optional(String.t()) => pos_integer()}
  def for_jobs(run, jobs, opts) do
    with path when is_binary(path) <- run["path"],
         sha when is_binary(sha) <- run["head_sha"],
         {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, body} <- fetch_workflow(owner, repo, path, sha, token, opts),
         %{"content" => encoded} when is_binary(encoded) <- body,
         {:ok, source} <- decode_content(encoded),
         {:ok, %{"jobs" => definitions}} when is_map(definitions) <- Aiur.Yaml.read_from_string(source) do
      Map.new(jobs, fn job ->
        name = job["name"]
        {name, timeout_for(name, definitions)}
      end)
      |> Enum.reject(fn {_name, timeout} -> not is_integer(timeout) end)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp fetch_workflow(owner, repo, path, sha, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    url_path = path |> String.split("/") |> Enum.map_join("/", &URI.encode/1)
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/contents/#{url_path}?" <> URI.encode_query(%{"ref" => sha})
    Transport.fetch_json_map(request, token, url, caller: "landing_watch_workflow_timeout")
  end

  defp decode_content(encoded) do
    case Base.decode64(String.replace(encoded, ~r/\s/, "")) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :invalid_workflow_content}
    end
  end

  defp timeout_for(name, definitions) do
    Enum.find_value(definitions, &matching_timeout(name, &1))
  end

  defp matching_timeout(name, {job_id, definition}) do
    if job_id == name or name_matches?(Map.get(definition, "name"), name),
      do: configured_timeout(definition),
      else: nil
  end

  # Matrix jobs name each run from an expression, e.g. "browser smoke (${{ matrix.shard }}/5)".
  defp name_matches?(pattern, name) when is_binary(pattern) and is_binary(name) do
    regex = pattern |> String.split(~r/\$\{\{.*?\}\}/) |> Enum.map_join(".+", &Regex.escape/1)
    Regex.match?(~r/\A#{regex}\z/, name)
  end

  defp name_matches?(_pattern, _name), do: false

  defp configured_timeout(definition) do
    case Map.get(definition, "timeout-minutes") do
      minutes when is_integer(minutes) and minutes > 0 -> minutes
      nil -> 360
      _ -> nil
    end
  end
end
