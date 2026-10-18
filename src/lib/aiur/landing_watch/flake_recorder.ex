defmodule Aiur.LandingWatch.FlakeRecorder do
  @moduledoc "Creates durable, deduplicated issue evidence for tests that fail only in one merge group."

  alias Aiur.GitHub.{AgentMarker, Errors, Transport}
  alias Aiur.LandingWatch.Journal

  # Priority 2: the quarantine PR unblocks the merge queue, so the fix need not preempt other work.
  @labels ["bug", "agent:todo", "priority:2", "flake"]

  @spec record(map(), map(), [pos_integer()], keyword()) :: :ok | {:error, term()}
  def record(failure, run, passed_prs, opts) do
    identity = "#{failure.module} :: #{failure.name}"
    claim_key = identity <> " :: run " <> to_string(run["id"])
    evidence = evidence(failure, run, passed_prs)

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      claim_and_record(claim_key, identity, evidence, owner, repo, token, opts)
    else
      {:error, _} = error -> error
    end
  end

  defp claim_and_record(claim_key, identity, evidence, owner, repo, token, opts) do
    case Journal.claim_flake(claim_key, opts) do
      {:ok, :already_claimed} -> :ok
      {:ok, :new} -> publish_claimed(claim_key, identity, evidence, owner, repo, token, opts)
      {:error, _} = error -> error
    end
  end

  defp publish_claimed(claim_key, identity, evidence, owner, repo, token, opts) do
    result = record_issue_and_emit(identity, evidence, owner, repo, token, opts)
    if result == :ok, do: :ok, else: release_claim(claim_key, opts, result)
  end

  defp release_claim(claim_key, opts, result) do
    _ = Journal.release_flake(claim_key, opts)
    result
  end

  defp record_issue_and_emit(identity, evidence, owner, repo, token, opts) do
    case find_or_create(owner, repo, token, identity, evidence, opts) do
      {:ok, issue} ->
        case emit(evidence, issue, opts) do
          :ok -> notify_issue_recorded(issue, opts)
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp notify_issue_recorded(issue, opts) do
    case Keyword.get(opts, :issue_recorded_fun) do
      fun when is_function(fun, 1) -> fun.(issue)
      _ -> :ok
    end
  end

  defp find_or_create(owner, repo, token, identity, evidence, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    query = URI.encode_query(%{"q" => "repo:#{owner}/#{repo} is:issue in:body \"#{marker_hash(identity)}\"", "per_page" => 100})
    url = "#{Transport.base_url()}/search/issues?#{query}"

    case request.(%{method: :get, url: url, token: token, caller: "landing_watch_flake_search"}) do
      {:ok, %{status: 200, body: %{"items" => issues}}} when is_list(issues) ->
        resolve_issue(issues, identity, evidence, request, token, owner, repo)

      {:ok, response} ->
        {:error, Errors.github_status_error(response)}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_issue(issues, identity, evidence, request, token, owner, repo) do
    case Enum.find(issues, &matching_issue?(&1, identity)) do
      %{"number" => number} when is_integer(number) -> comment_existing(number, evidence, request, token, owner, repo)
      nil -> create_issue(identity, evidence, request, token, owner, repo)
      _ -> {:error, :invalid_flake_issue}
    end
  end

  defp comment_existing(number, evidence, request, token, owner, repo) do
    with :ok <- add_flake_label(number, request, token, owner, repo),
         :ok <- comment(number, evidence, request, token, owner, repo) do
      {:ok, number}
    end
  end

  defp add_flake_label(number, request, token, owner, repo) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{number}/labels"

    case request.(%{method: :post, url: url, token: token, caller: "landing_watch_flake_label", body: %{"labels" => ["flake"]}}) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp matching_issue?(%{"pull_request" => _}, _identity), do: false
  defp matching_issue?(%{"body" => body}, identity) when is_binary(body), do: String.contains?(body, marker(identity))
  defp matching_issue?(_, _), do: false

  defp create_issue(identity, evidence, request, token, owner, repo) do
    title = "Flaky test: " <> identity
    body = marker(identity) <> "\n\n" <> evidence
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues"

    case request.(%{method: :post, url: url, token: token, caller: "landing_watch_flake_issue", body: %{"title" => title, "body" => body, "labels" => @labels}}) do
      {:ok, %{status: status, body: %{"number" => number}}} when status in [200, 201] and is_integer(number) -> {:ok, number}
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp comment(number, evidence, request, token, owner, repo) do
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/issues/#{number}/comments"
    body = AgentMarker.stamp(evidence)

    case request.(%{method: :post, url: url, token: token, caller: "landing_watch_flake_comment", body: %{"body" => body}}) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, response} -> {:error, Errors.github_status_error(response)}
      {:error, _} = error -> error
    end
  end

  defp evidence(failure, run, passed_prs) do
    [
      "Run ID: #{run["id"]}",
      "Run: #{run["html_url"] || "unknown"}",
      "Job: #{failure.job}",
      "Failing test: #{failure.module} :: #{failure.name}",
      "Error excerpt: #{failure.excerpt}",
      "PRs that passed this test in another merge group containing the PR: #{Enum.map_join(passed_prs, ", ", &"##{&1}")}"
    ]
    |> Enum.join("\n")
  end

  defp marker(identity), do: "<!-- aiur-flake-key: #{marker_hash(identity)} -->"
  defp marker_hash(identity), do: Base.encode16(:crypto.hash(:sha256, identity), case: :lower)

  defp emit(evidence, issue, opts) do
    emitter = Keyword.get(opts, :alert_emitter, &Aiur.Alerts.emit_system/2)
    message = "Flaky test recorded in issue ##{issue}.\n" <> evidence

    emitter.("system.pr.landing.flake_recorded",
      central: true,
      durable: true,
      needs_attention: false,
      # The issue was just filed, so the contamination filter does not track it yet; without
      # this the durable publish is :filtered and the quarantine PR is never opened.
      bypass_contamination: true,
      issue: Integer.to_string(issue),
      message: message,
      reason: message,
      exchange_payload: %{"flake_evidence" => evidence, "flake_issue_number" => issue}
    )
  end
end
