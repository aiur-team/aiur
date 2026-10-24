defmodule Aiur.LandingWatch.ConflictUpdate do
  @moduledoc """
  Merges the base into an approved conflicting PR with GitHub's update-branch before any rework turn (#6088).

  Only an approved, non-draft PR outside the merge queue is updated: a queued PR
  cannot be updated, and a dequeue resets the merge groups. Each PR head gets at
  most one call per base SHA, and every call takes a slot of the shared
  automatic-requeue cap (four per 15 minutes) because each one starts a CI run.
  An accepted update re-arms auto-merge so the PR re-enters the queue after CI.
  A refused update names the conflicting files, computed with a local
  `git merge-tree`, for the rebase-only rework comment.
  """

  alias Aiur.GitHub.{CIRecovery, Transport}
  alias Aiur.LandingWatch.{Classifier, Journal}
  alias Aiur.PrMerge.MergeResult

  @caller "landing_watch_conflict_update"
  @auto_merge "mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { number } } }"

  @type result :: :updated | :held | :skip | {:refused, [String.t()]} | {:error, term()}

  @spec attempt(map(), keyword()) :: result()
  def attempt(observation, opts) do
    if eligible?(observation), do: attempt_eligible(observation, opts), else: :skip
  end

  # reviewDecision APPROVED at the head also rules out a request-changes review at the head.
  defp eligible?(%{merge_queue_entry: nil, draft?: false, raw: raw, base_oid: base, number: number, head: head})
       when is_binary(base) and base != "" and is_integer(number) and is_binary(head),
       do: Classifier.approved_at_head?(raw)

  defp eligible?(_observation), do: false

  defp attempt_eligible(observation, opts) do
    with {:ok, state} <- Journal.state(opts) do
      case get_in(state, [key(observation), "update_branch"]) do
        %{"base" => base, "result" => "accepted"} when base == observation.base_oid -> :held
        %{"base" => base, "result" => "refused", "files" => files} when base == observation.base_oid -> {:refused, files}
        _ -> reserve_and_update(observation, opts)
      end
    end
  end

  defp reserve_and_update(observation, opts) do
    case Journal.reserve_merge_group_requeue(Keyword.get(opts, :now_ms, System.system_time(:millisecond)), opts) do
      :ok -> update(observation, opts)
      {:error, :merge_group_requeue_limit_reached} -> :held
      {:error, _} = error -> error
    end
  end

  defp update(observation, opts) do
    github_opts = Keyword.put(opts, :caller, @caller)

    case Keyword.get(opts, :update_branch_fun, &CIRecovery.update_branch/3).(observation.number, observation.head, github_opts) do
      {:ok, _} ->
        with :ok <- record(observation, %{"result" => "accepted"}, opts),
             :ok <- arm_auto_merge(observation, github_opts),
             do: :updated

      {:error, {:github, :http, %{status: 422}}} ->
        files =
          case Keyword.get(opts, :conflict_files_fun, &conflict_files/2).(observation, opts) do
            {:ok, files} when is_list(files) -> files
            _ -> []
          end

        with :ok <- record(observation, %{"result" => "refused", "files" => files}, opts), do: {:refused, files}

      {:error, _} = error ->
        error
    end
  end

  defp record(observation, row, opts) do
    Journal.update(opts, fn state ->
      entry = Map.get(state, key(observation), %{})
      {:ok, Map.put(state, key(observation), Map.put(entry, "update_branch", Map.put(row, "base", observation.base_oid)))}
    end)
  end

  defp arm_auto_merge(%{auto_merge_request: request}, _opts) when is_map(request), do: :ok

  defp arm_auto_merge(%{node_id: id} = observation, opts) when is_binary(id) do
    case Keyword.get(opts, :auto_merge_fun, &enable_auto_merge/2).(id, opts) do
      :ok -> :ok
      {:error, reason} -> auto_merge_attention(observation, reason, opts)
    end
  end

  defp arm_auto_merge(observation, opts), do: auto_merge_attention(observation, :missing_pull_request_node_id, opts)

  # The update already landed, so a retry cannot re-arm it; the Executor re-enqueues by hand.
  defp auto_merge_attention(observation, reason, opts) do
    message = "Landing watcher merged the base into approved PR ##{observation.number}, but auto-merge could not be armed (#{inspect(reason)}); re-enqueue it after CI."
    emitter = Keyword.get(opts, :alert_emitter, &Aiur.Alerts.emit_system/2)
    _ = emitter.("system.pr.landing.conflict_update_unarmed", central: true, durable: true, needs_attention: true, message: message, reason: message)
    :ok
  end

  defp enable_auto_merge(id, opts) do
    with {:ok, token} <- Transport.require_token(opts) do
      case Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, @auto_merge, %{"id" => id}, caller: @caller) do
        {:ok, %{"data" => %{"enablePullRequestAutoMerge" => %{}}}} -> :ok
        {:ok, _} -> {:error, :auto_merge_unconfirmed}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Files that conflict when the PR head merges its base, from a persistent local bare cache."
  @spec conflict_files(map(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def conflict_files(%{number: number, base: base}, opts) when is_integer(number) and is_binary(base) do
    with {:ok, {remote, env}} <- remote(opts) do
      cache = Keyword.get_lazy(opts, :conflict_cache, &default_cache/0)
      run = Keyword.get(opts, :git_fun, &MergeResult.git/3)
      git = fn args -> run.(cache, args, env) end

      with :ok <- File.mkdir_p(cache),
           {:ok, {_, 0}} <- git.(["init", "--bare", "--quiet"]),
           {:ok, {_, 0}} <- git.(["fetch", "--no-tags", "--quiet", remote, "+refs/heads/#{base}:refs/aiur/conflict/base", "+refs/pull/#{number}/head:refs/aiur/conflict/head"]) do
        merge_tree_files(git.(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "refs/aiur/conflict/base", "refs/aiur/conflict/head"]))
      else
        _ -> {:error, :conflict_fetch_failed}
      end
    end
  end

  def conflict_files(_observation, _opts), do: {:error, :invalid_conflict_observation}

  # With -z the output is the tree OID, then each conflicted path, NUL-separated.
  defp merge_tree_files({:ok, {_output, 0}}), do: {:ok, []}
  defp merge_tree_files({:ok, {output, 1}}), do: {:ok, output |> String.split("\0", trim: true) |> tl() |> Enum.uniq()}
  defp merge_tree_files(_result), do: {:error, :merge_tree_failed}

  defp remote(opts) do
    case Keyword.get(opts, :conflict_remote) do
      remote when is_binary(remote) ->
        {:ok, {remote, []}}

      _ ->
        with {:ok, {owner, repo}} <- Transport.parse_repo(), {:ok, token} <- Transport.require_token(opts) do
          header = "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> token)
          env = [{"GIT_CONFIG_COUNT", "1"}, {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"}, {"GIT_CONFIG_VALUE_0", header}, {"GIT_TERMINAL_PROMPT", "0"}]
          {:ok, {"https://github.com/#{owner}/#{repo}.git", env}}
        end
    end
  end

  defp default_cache do
    {:ok, {owner, repo}} = Transport.parse_repo()
    Path.expand("~/.aiur/repo/#{owner}/#{repo}/conflict-files.git")
  end

  defp key(observation), do: "#{observation.number}:#{observation.head}"
end
