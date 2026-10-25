defmodule Aiur.LandingWatch.ConflictUpdate do
  @moduledoc """
  Merges the base into an approved conflicting PR with GitHub's update-branch before any rework turn (#6088).

  Only an approved, non-draft PR outside the merge queue is updated, and only
  when its ticket is this instance's and sits in `human-review`, `ci-wait` or
  `merging` without an Executor hold: the same states the rework path writes
  for, so no branch with a live agent or another instance's ticket gets a push.
  A queued PR cannot be updated, and a dequeue resets the merge groups. Each PR
  head gets at most one call per base SHA, and every call takes a slot of the
  shared automatic-requeue cap (four per 15 minutes) because each one starts a
  CI run. An accepted update re-arms auto-merge so the PR re-enters the queue
  after CI; an arm that fails is retried on the merge head on later polls. A
  refused update names the conflicting files, computed with a local
  `git merge-tree`, for the rebase-only rework comment.
  """

  alias Aiur.Config.Paths
  alias Aiur.GitHub.{CIRecovery, Transport}
  alias Aiur.LandingWatch.{Classifier, Journal, TicketLookup}

  @caller "landing_watch_conflict_update"
  @auto_merge "mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { number } } }"
  @owned_states ["human-review", "ci-wait", "merging"]
  @arm_attempts 5

  @type result :: :updated | :held | :skip | {:refused, [String.t()]} | {:error, term()}

  @spec attempt(map(), keyword()) :: result()
  def attempt(observation, opts) do
    if eligible?(observation), do: attempt_unheld(observation, opts), else: :skip
  end

  defp attempt_unheld(%{number: number, head: head} = observation, opts) do
    case Journal.merge_group_head_held?(number, head, opts) do
      {:ok, true} -> :held
      {:ok, false} -> attempt_owned(observation, opts)
      {:error, _} = error -> error
    end
  end

  # reviewDecision APPROVED at the head also rules out a request-changes review at the head.
  defp eligible?(%{merge_queue_entry: nil, draft?: false, raw: raw, base_oid: base, number: number, head: head})
       when is_binary(base) and base != "" and is_integer(number) and is_binary(head),
       do: Classifier.approved_at_head?(raw)

  defp eligible?(_observation), do: false

  defp attempt_owned(observation, opts) do
    case TicketLookup.fetch(observation, opts) do
      {:ok, _issue, state, _paused?, false} when state in @owned_states -> attempt_eligible(observation, opts)
      {:ok, _issue, _state, _paused?, _held?} -> :skip
      {:error, :pull_request_not_linked_to_ticket_branch} -> :skip
      {:error, _} = error -> error
    end
  end

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
             :ok <- put_arm(observation, opts),
             :ok <- arm(observation, observation.head, github_opts),
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

  @doc """
  Retries a failed auto-merge arm once GitHub's merge commit is the PR head.

  The merge head carries no approval, so the normal landing path skips it; the
  arm row from the accepted update is what lets this poll finish the job. Only a
  head whose parents include the updated head is armed, so a later push by
  anyone else never inherits the approval.
  """
  @spec retry_arm(map(), keyword()) :: :ok | {:error, term()}
  def retry_arm(%{number: number, head: head} = observation, opts) when is_integer(number) and is_binary(head) do
    with {:ok, state} <- Journal.state(opts) do
      case get_in(state, ["conflict_update_arms", to_string(number)]) do
        %{"from" => ^head} -> :ok
        %{} = row -> retry_arm_row(observation, row, opts)
        _ -> :ok
      end
    end
  end

  def retry_arm(_observation, _opts), do: :ok

  defp retry_arm_row(%{auto_merge_request: request} = observation, _row, opts) when is_map(request), do: drop_arm(observation, opts)

  defp retry_arm_row(observation, %{"from" => from} = row, opts) do
    cond do
      from not in Map.get(observation, :head_parents, []) -> drop_arm(observation, opts)
      Map.get(row, "attempts", 0) >= @arm_attempts -> :ok
      true -> arm(observation, from, Keyword.put(opts, :caller, @caller))
    end
  end

  defp put_arm(observation, opts) do
    Journal.update(opts, fn state ->
      arms = Map.get(state, "conflict_update_arms", %{})
      {:ok, Map.put(state, "conflict_update_arms", Map.put(arms, to_string(observation.number), %{"from" => observation.head, "attempts" => 0}))}
    end)
  end

  defp arm(%{auto_merge_request: request} = observation, _from, opts) when is_map(request), do: drop_arm(observation, opts)

  defp arm(%{node_id: id} = observation, from, opts) when is_binary(id) do
    case Keyword.get(opts, :auto_merge_fun, &enable_auto_merge/2).(id, opts) do
      :ok -> drop_arm(observation, opts)
      {:error, reason} -> count_failed_arm(observation, from, reason, opts)
    end
  end

  defp arm(observation, from, opts), do: count_failed_arm(observation, from, :missing_pull_request_node_id, opts)

  defp drop_arm(observation, opts) do
    Journal.update(opts, fn state ->
      arms = Map.get(state, "conflict_update_arms", %{})
      {:ok, Map.put(state, "conflict_update_arms", Map.delete(arms, to_string(observation.number)))}
    end)
  end

  # A failed arm stays queued for the next poll; only the last allowed attempt asks the Executor.
  defp count_failed_arm(observation, from, reason, opts) do
    result =
      Journal.update(opts, fn state ->
        arms = Map.get(state, "conflict_update_arms", %{})
        attempts = get_in(arms, [to_string(observation.number), "attempts"]) || 0
        row = %{"from" => from, "attempts" => attempts + 1}
        {:ok, Map.put(state, "conflict_update_arms", Map.put(arms, to_string(observation.number), row)), attempts + 1}
      end)

    case result do
      {:ok, @arm_attempts} -> auto_merge_attention(observation, reason, opts)
      {:ok, _attempts} -> :ok
      {:error, _} = error -> error
    end
  end

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

  defp record(observation, row, opts) do
    Journal.update(opts, fn state ->
      entry = Map.get(state, key(observation), %{})
      {:ok, Map.put(state, key(observation), Map.put(entry, "update_branch", Map.put(row, "base", observation.base_oid)))}
    end)
  end

  @doc "Files that conflict when the PR head merges its base, from a persistent local bare cache."
  @spec conflict_files(map(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def conflict_files(%{number: number, base: base}, opts) when is_integer(number) and is_binary(base) do
    with {:ok, {remote, env}} <- remote(opts) do
      cache = Keyword.get_lazy(opts, :conflict_cache, &default_cache/0)
      # Per-PR refs: daemons sharing ~/.aiur must not overwrite each other's head between fetch and merge-tree.
      refs = "refs/aiur/conflict/#{number}"
      git = fn args -> git(cache, args, env) end

      with :ok <- File.mkdir_p(cache),
           {_, 0} <- git.(["init", "--bare", "--quiet"]),
           {_, 0} <- git.(["fetch", "--no-tags", "--quiet", remote, "+refs/heads/#{base}:#{refs}/base", "+refs/pull/#{number}/head:#{refs}/head"]) do
        merge_tree_files(git.(["merge-tree", "--write-tree", "--name-only", "--no-messages", "-z", "#{refs}/base", "#{refs}/head"]))
      else
        _ -> {:error, :conflict_fetch_failed}
      end
    end
  end

  def conflict_files(_observation, _opts), do: {:error, :invalid_conflict_observation}

  # With -z the output is the tree OID, then each conflicted path, NUL-separated.
  defp merge_tree_files({_output, 0}), do: {:ok, []}
  defp merge_tree_files({output, 1}), do: {:ok, output |> String.split("\0", trim: true) |> tl() |> Enum.uniq()}
  defp merge_tree_files(_result), do: {:error, :merge_tree_failed}

  # stderr stays out of the parsed -z output; the low-speed limit aborts a stalled fetch.
  defp git(cache, args, env) do
    env = [{"GIT_HTTP_LOW_SPEED_LIMIT", "1000"}, {"GIT_HTTP_LOW_SPEED_TIME", "60"} | env]
    System.cmd("git", ["-C", cache | args], env: env)
  rescue
    _ -> {"", 127}
  end

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
    Path.join([Paths.state_root(), "repo", owner, repo, "conflict-files.git"])
  end

  defp key(observation), do: "#{observation.number}:#{observation.head}"
end
