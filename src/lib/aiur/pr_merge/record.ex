defmodule Aiur.PrMerge.Record do
  @moduledoc false
  alias Aiur.ControlCLI.Protocol
  alias Aiur.Events.Publisher
  alias Aiur.GitHub.Transport
  alias Aiur.JSONSafe
  @spec append(map(), String.t()) :: :ok | {:error, term()}
  def append(record, root) do
    with :ok <- File.mkdir_p(root), do: File.write(Path.join(root, "merges.ndjson"), Jason.encode!(record) <> "\n", [:append, :sync])
  end

  @spec notify(map()) :: :ok | {:error, term()}
  def notify(record) do
    case System.get_env("AIUR_PR_MERGE_ENGINE") do
      nil -> {:error, :no_launcher}
      engine -> notify(engine, record)
    end
  end

  defp notify(engine, record) do
    encoded = record |> Jason.encode!() |> Base.encode64()

    case System.cmd("bash", [engine, "__pr-merge-record", encoded], stderr_to_stdout: true, env: [{"GH_TOKEN", nil}, {"GITHUB_TOKEN", nil}]) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :daemon_unavailable}
    end
  end

  @spec watcher_state() :: map()
  def watcher_state do
    case System.get_env("AIUR_PR_MERGE_ENGINE") do
      nil ->
        %{}

      engine ->
        engine |> state_request() |> decode_state()
    end
  end

  defp state_request(engine), do: System.cmd("bash", [engine, "__pr-merge-state"], stderr_to_stdout: true, env: [{"GH_TOKEN", nil}, {"GITHUB_TOKEN", nil}])

  defp decode_state({json, 0}) do
    case Jason.decode(String.trim(json)) do
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  end

  defp decode_state(_response), do: %{}

  @spec print_watcher_state() :: :ok
  def print_watcher_state do
    module = Module.concat([Aiur, MainWatch])
    state = if Code.ensure_loaded?(module) and function_exported?(module, :state, 0), do: module.state(), else: %{}
    IO.puts(Jason.encode!(JSONSafe.normalize(state)))
    Protocol.exit_marker(0)
  end

  @spec publish(String.t()) :: :ok
  def publish(encoded) do
    Protocol.exit_marker(if verify_and_publish(encoded) == :ok, do: 0, else: 1)
  end

  @spec verify_and_publish(String.t(), keyword()) :: :ok | {:error, :unverified_merge}
  def verify_and_publish(encoded, opts \\ []) do
    with {:ok, json} <- Base.decode64(encoded),
         {:ok, %{"repo" => repo, "pr" => number, "sha" => head, "merged_sha" => merged_sha}} <- Jason.decode(json),
         true <- is_integer(number) and number > 0 and is_binary(head) and is_binary(merged_sha),
         {:ok, settings} <- Keyword.get(opts, :settings, &Aiur.Config.settings_uncached/0).(),
         true <- repo == settings.tracker.github.repo,
         {:ok, token} <- Transport.require_token(opts),
         request <- Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
         {:ok, raw} <- Transport.fetch_json_map(request, token, "https://api.github.com/repos/#{repo}/pulls/#{number}", caller: "pr_merge_record_verification"),
         %{
           "merged" => true,
           "state" => "closed",
           "head" => %{"sha" => ^head},
           "merge_commit_sha" => ^merged_sha,
           "base" => %{"ref" => base},
           "merged_by" => %{"login" => actor},
           "merged_at" => merged_at
         } <- raw,
         true <- base == settings.tracker.base_branch and is_binary(actor) and is_binary(merged_at),
         verified <- %{repo: repo, pr: number, sha: head, merged_sha: merged_sha, state: "merged", actor: actor, merged_at: merged_at},
         {:ok, _id, _subscribers} <- Keyword.get(opts, :publish, &Publisher.publish/3).("system.pr.merged", verified, source: :pr_merge_cli) do
      :ok
    else
      _ -> {:error, :unverified_merge}
    end
  end
end
