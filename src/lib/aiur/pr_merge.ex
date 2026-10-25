defmodule Aiur.PrMerge do
  @moduledoc "Standalone, operator-only merge or merge-queue enqueue with policy gates."
  alias Aiur.PrMerge.{Client, Facts, Gate, Identity, MergeResult, Queue, Record}

  @spec run(map(), keyword()) :: non_neg_integer()
  def run(opts, deps \\ []) do
    puts = Keyword.get(deps, :puts, &IO.puts/1)
    report(execute(opts, deps, puts), puts)
  rescue
    _error ->
      IO.puts(:stderr, "aiur pr merge: unexpected tool failure; merge outcome may be unknown")
      1
  end

  defp execute(opts, deps, puts) do
    with {:ok, settings} <- Keyword.get(deps, :settings, &Aiur.Config.settings_uncached/0).(),
         :ok <- Identity.guard(settings, Keyword.get(deps, :cwd, File.cwd!()), Keyword.get(deps, :agent_bin, System.get_env("AIUR_AGENT_BIN"))),
         {:ok, token} <- Keyword.get(deps, :token, &Identity.token/0).(),
         api <- Keyword.get(deps, :api, &Client.request(token, &1, &2, &3)),
         {:ok, user} <- api.("get", "user", nil),
         :ok <- Identity.allowed(user, settings.tracker.github),
         :ok <- main_note(settings, deps, puts),
         {:ok, observation} <- Facts.observe(api, settings, opts.number) do
      observed(api, observation, settings, opts, token, deps, puts, user)
    end
  end

  defp observed(_api, %{merged: true} = pr, settings, opts, _token, deps, puts, _user) do
    cond do
      pr.state != "CLOSED" ->
        {:error, "inconsistent GitHub merged observation"}

      pr.head != opts.reviewed_sha ->
        {:refuse, ["merged PR head differs from reviewed head"]}

      not (is_binary(pr.merge_commit_sha) and is_binary(pr.merged_by) and is_binary(pr.merged_at)) ->
        {:error, "incomplete GitHub merged observation"}

      opts.dry_run ->
        puts.("DRY RUN observed MERGED ##{pr.number} #{pr.merge_commit_sha}; no record written")
        :ok

      true ->
        root = Keyword.get(deps, :log_root, Path.expand("~/.aiur/logs/pr-merge"))

        record = %{
          repo: settings.tracker.github.repo,
          pr: pr.number,
          sha: pr.head,
          base_sha: pr.base_sha,
          state: "merged",
          merged_sha: pr.merge_commit_sha,
          merged_at: pr.merged_at,
          actor: pr.merged_by,
          policy: settings.merge_policy.ci,
          pending: [],
          pending_count: 0
        }

        puts.("MERGED ##{pr.number} #{pr.merge_commit_sha}; observed GitHub merge")
        record(record, root, deps, puts)
        :ok
    end
  end

  defp observed(api, _observation, settings, opts, token, deps, puts, user) do
    with {:ok, pr} <- Facts.read(api, settings, opts.number, user),
         :ok <- preflight(pr, settings, opts),
         :ok <- merge_result(pr, settings, token, deps, puts),
         {:ok, fresh} <- Facts.read(api, settings, opts.number, user),
         :ok <- preflight(fresh, settings, opts),
         true <- fresh.base_sha == pr.base_sha or {:refuse, ["base moved during premerge checks; rerun"]} do
      finish(api, fresh, settings, opts, deps, puts, user)
    end
  end

  defp main_note(settings, deps, puts) do
    if settings.merge_policy.main_watch.enabled do
      case Keyword.get(deps, :watcher_state, &Record.watcher_state/0).() do
        %{"status" => "red", "red_since" => since} = state -> puts.("NOTE integration branch is red since #{since} (fixer #{state["fixer_identifier"] || "unavailable"})")
        _ -> :ok
      end
    end

    :ok
  end

  defp preflight(pr, settings, opts) do
    reasons = Gate.refusals(pr, settings.merge_policy, opts)
    reasons = if opts.approve_body != nil and not opts.dry_run, do: List.delete(reasons, "approval at current head required"), else: reasons
    if reasons == [], do: :ok, else: {:refuse, reasons}
  end

  defp gate(pr, settings, opts) do
    case Gate.refusals(pr, settings.merge_policy, opts) do
      [] -> :ok
      reasons -> {:refuse, reasons}
    end
  end

  defp merge_result(pr, settings, token, deps, puts) do
    repo = settings.tracker.github.repo
    encoded = Base.encode64("x-access-token:" <> token)
    env = [{"GIT_CONFIG_COUNT", "1"}, {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"}, {"GIT_CONFIG_VALUE_0", "AUTHORIZATION: basic " <> encoded}, {"GIT_TERMINAL_PROMPT", "0"}]
    options = [repo: Path.expand("~/.aiur/repo/#{repo}/pr-merge.git"), remote: "https://github.com/#{repo}.git", env: env, puts: puts]
    Keyword.get(deps, :merge_result, &MergeResult.check/3).(pr, settings, options)
  end

  defp finish(_api, pr, settings, %{dry_run: true}, _deps, puts, _user) do
    puts.("DRY RUN policy ci=#{settings.merge_policy.ci}; pending=#{Enum.join(Gate.pending(pr), ",")}; nothing merged")
    :ok
  end

  defp finish(api, pr, settings, opts, deps, puts, user) do
    root = Keyword.get(deps, :log_root, Path.expand("~/.aiur/logs/pr-merge"))
    repo = settings.tracker.github.repo

    with :ok <- File.mkdir_p(root),
         :ok <- approve(api, repo, pr, opts.approve_body),
         {:ok, fresh} <- Facts.read(api, settings, pr.number, user),
         :ok <- gate(fresh, settings, opts),
         true <- fresh.base_sha == pr.base_sha or {:refuse, ["base moved during approval; rerun"]} do
      deliver(api, fresh, settings, root, deps, puts, user)
    end
  end

  defp deliver(api, %{merge_queue: true} = pr, settings, root, _deps, puts, user) do
    with {:ok, entry} <- Queue.enqueue(api, pr) do
      record = record_data(pr, settings, user) |> Map.merge(%{state: "enqueued", queue_entry: entry, enqueued_at: DateTime.to_iso8601(DateTime.utc_now())})
      puts.("ENQUEUED ##{pr.number} #{pr.head}; policy ci=#{record.policy}; pending=#{Enum.join(record.pending, ",")}")
      if Record.append(record, root) != :ok, do: puts.("WARNING enqueued, but queue ledger write failed")
      :ok
    end
  end

  defp deliver(api, %{merge_queue: false} = pr, settings, root, deps, puts, user) do
    repo = settings.tracker.github.repo

    case api.("put", "repos/#{repo}/pulls/#{pr.number}/merge", merge_body(pr)) do
      {:ok, %{"merged" => true, "sha" => sha}} ->
        record = record_data(pr, settings, user) |> Map.merge(%{state: "merged", merged_sha: sha, merged_at: DateTime.to_iso8601(DateTime.utc_now())})
        puts.("MERGED ##{pr.number} #{sha}; policy ci=#{record.policy}; pending=#{Enum.join(record.pending, ",")}")
        record(record, root, deps, puts)
        :ok

      {:ok, %{"message" => message}} ->
        {:error, message}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, "GitHub did not confirm a merge"}
    end
  end

  defp record_data(pr, settings, user) do
    %{
      repo: settings.tracker.github.repo,
      pr: pr.number,
      sha: pr.head,
      base_sha: pr.base_sha,
      pending: Gate.pending(pr),
      pending_count: length(Gate.pending(pr)),
      policy: settings.merge_policy.ci,
      actor: user["login"]
    }
  end

  defp approve(_api, _repo, _pr, nil), do: :ok

  defp approve(api, repo, pr, body) do
    case api.("post", "repos/#{repo}/pulls/#{pr.number}/reviews", %{event: "APPROVE", body: body, commit_id: pr.head}) do
      {:ok, %{"state" => "APPROVED", "commit_id" => head}} when head == pr.head -> :ok
      {:error, _} = error -> error
      _ -> {:error, "GitHub did not confirm approval at the reviewed head"}
    end
  end

  defp merge_body(pr), do: %{merge_method: "squash", sha: pr.head, commit_title: "#{pr.title} (##{pr.number})", commit_message: ""}

  defp record(record, root, deps, puts) do
    if Record.append(record, root) != :ok, do: puts.("WARNING merged, but merge ledger write failed")
    if Keyword.get(deps, :notify, &Record.notify/1).(record) != :ok, do: puts.("WARNING merged, but daemon event delivery failed")
  end

  defp report(:ok, _puts), do: 0

  defp report({:refuse, reasons}, puts) do
    Enum.each(reasons, &puts.("REFUSE " <> &1))
    2
  end

  defp report({:error, reason}, puts) do
    puts.("ERROR " <> inspect(reason))
    1
  end
end
