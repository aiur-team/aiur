defmodule Aiur.PrMerge do
  @moduledoc "Standalone, operator-only merge or merge-queue enqueue with policy gates."
  alias Aiur.PrMerge.{Client, Facts, Gate, Identity, MergeResult, Queue, Record}
  require Logger

  @spec run(map(), keyword()) :: non_neg_integer()
  def run(opts, deps \\ []) do
    puts = Keyword.get(deps, :puts, &IO.puts/1)
    state = %{step: :settings, settings: nil, opts: opts, deps: deps, delivered?: false, merged_observed?: false}
    Process.put({__MODULE__, :state}, state)
    Process.put({__MODULE__, :step}, :settings)

    try do
      case execute(opts, deps, puts, state) do
        {:error, reason} ->
          error = RuntimeError.exception(format_error(reason))
          failure(state, error, current_stacktrace(), puts)

        result ->
          report(result, puts)
      end
    rescue
      error ->
        failure(state, error, __STACKTRACE__, puts)
    catch
      kind, reason ->
        failure(state, RuntimeError.exception("#{kind}: #{format_error(reason)}"), __STACKTRACE__, puts)
    after
      Process.delete({__MODULE__, :state})
      Process.delete({__MODULE__, :step})
    end
  end

  defp execute(opts, deps, puts, state) do
    settings = step(state, :settings, fn -> Keyword.get(deps, :settings, &Aiur.Config.settings_uncached/0).() end)

    case settings do
      {:ok, settings} ->
        Process.put({__MODULE__, :state}, %{state | settings: settings})
        execute_with_settings(opts, deps, puts, state, settings)

      other ->
        other
    end
  end

  defp execute_with_settings(opts, deps, puts, state, settings) do
    with :ok <- step(state, :identity_guard, fn -> Identity.guard(settings, Keyword.get(deps, :cwd, File.cwd!()), Keyword.get(deps, :agent_bin, System.get_env("AIUR_AGENT_BIN"))) end),
         {:ok, token} <- step(state, :token, fn -> Keyword.get(deps, :token, &Identity.token/0).() end),
         api <- Keyword.get(deps, :api, &Client.request(token, &1, &2, &3)),
         {:ok, user} <- step(state, :viewer, fn -> api.("get", "user", nil) end),
         :ok <- Identity.allowed(user, settings.tracker.github),
         :ok <- step(state, :observe, fn -> main_note(settings, deps, puts) end),
         {:ok, observation} <- step(state, :facts, fn -> Facts.observe(api, settings, opts.number) end) do
      observed(api, observation, settings, opts, token, deps, puts, user)
    end
  end

  defp step(state, name, fun) do
    Process.put({__MODULE__, :step}, name)
    current = Process.get({__MODULE__, :state}, state)
    Process.put({__MODULE__, :state}, %{current | step: name, delivered?: current.delivered? or name == :deliver})

    run = Keyword.get(state.deps, :step, fn _name, callback -> callback.() end)
    run.(name, fun)
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
        mark_merged_observed()

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
        step(run_state(), :record, fn -> record(record, root, deps, puts) end)
        :ok
    end
  end

  defp observed(api, _observation, settings, opts, token, deps, puts, user) do
    state = run_state()

    with {:ok, pr} <- step(state, :facts, fn -> Facts.read(api, settings, opts.number, user) end),
         :ok <- preflight(pr, settings, opts),
         :ok <- step(state, :merge_result, fn -> merge_result(pr, settings, token, deps, puts) end),
         {:ok, fresh} <- step(state, :facts, fn -> Facts.read(api, settings, opts.number, user) end),
         :ok <- preflight(fresh, settings, opts),
         true <- fresh.base_sha == pr.base_sha or {:refuse, ["base moved during premerge checks; rerun"]} do
      finish(api, fresh, settings, opts, deps, puts, user, run_state())
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

  defp finish(_api, pr, settings, %{dry_run: true}, _deps, puts, _user, _state) do
    puts.("DRY RUN policy ci=#{settings.merge_policy.ci}; pending=#{Enum.join(Gate.pending(pr), ",")}; nothing merged")
    :ok
  end

  defp finish(api, pr, settings, opts, deps, puts, user, state) do
    root = Keyword.get(deps, :log_root, Path.expand("~/.aiur/logs/pr-merge"))
    repo = settings.tracker.github.repo

    with :ok <- step(state, :record_setup, fn -> File.mkdir_p(root) end),
         :ok <- step(state, :approve, fn -> approve(api, repo, pr, opts.approve_body) end),
         {:ok, fresh} <- step(state, :facts, fn -> Facts.read(api, settings, pr.number, user) end),
         :ok <- gate(fresh, settings, opts),
         true <- fresh.base_sha == pr.base_sha or {:refuse, ["base moved during approval; rerun"]} do
      step(state, :deliver, fn -> deliver(api, fresh, settings, root, deps, puts, user) end)
    end
  end

  defp deliver(api, %{merge_queue: true} = pr, settings, root, deps, puts, user) do
    with {:ok, entry} <- Queue.enqueue(api, pr) do
      record = record_data(pr, settings, user) |> Map.merge(%{state: "enqueued", queue_entry: entry, enqueued_at: DateTime.to_iso8601(DateTime.utc_now())})
      puts.("ENQUEUED ##{pr.number} #{pr.head}; policy ci=#{record.policy}; pending=#{Enum.join(record.pending, ",")}")

      step(run_state(), :record, fn -> append_queue_record(record, root, deps, puts) end)

      :ok
    end
  end

  defp deliver(api, %{merge_queue: false} = pr, settings, root, deps, puts, user) do
    repo = settings.tracker.github.repo

    case api.("put", "repos/#{repo}/pulls/#{pr.number}/merge", merge_body(pr)) do
      {:ok, %{"merged" => true, "sha" => sha}} ->
        record = record_data(pr, settings, user) |> Map.merge(%{state: "merged", merged_sha: sha, merged_at: DateTime.to_iso8601(DateTime.utc_now())})
        puts.("MERGED ##{pr.number} #{sha}; policy ci=#{record.policy}; pending=#{Enum.join(record.pending, ",")}")
        step(run_state(), :record, fn -> record(record, root, deps, puts) end)
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
    if append_record(deps).(record, root) != :ok, do: puts.("WARNING merged, but merge ledger write failed")
    if Keyword.get(deps, :notify, &Record.notify/1).(record) != :ok, do: puts.("WARNING merged, but daemon event delivery failed")
  end

  defp append_record(deps), do: Keyword.get(deps, :append_record, &Record.append/2)

  defp append_queue_record(record, root, deps, puts) do
    if append_record(deps).(record, root) != :ok, do: puts.("WARNING enqueued, but queue ledger write failed")
  end

  defp run_state, do: Process.get({__MODULE__, :state})

  defp report(:ok, _puts), do: 0

  defp report({:refuse, reasons}, puts) do
    Enum.each(reasons, &puts.("REFUSE " <> &1))
    2
  end

  defp report({:error, reason}, puts) do
    puts.("ERROR " <> inspect(reason))
    1
  end

  defp failure(state, error, stacktrace, puts) do
    step_name = failure_step(Process.get({__MODULE__, :step}, state.step))
    state = Process.get({__MODULE__, :state}, state)
    message = Exception.message(error)
    safe_message = redact_token(message)
    outcome = failure_outcome(state)
    formatted = Exception.format(:error, error, stacktrace) |> redact_token()
    Logger.error("aiur pr merge: #{step_name} failed: #{safe_message}; #{outcome}\n#{formatted}")
    puts.("aiur pr merge: #{step_name} failed: #{safe_message}; #{outcome}")
    failure_record(state, step_name, safe_message)
    1
  end

  defp failure_record(state, step_name, message) do
    settings = state.settings

    record = %{
      repo: if(settings, do: settings.tracker.github.repo),
      pr: state.opts.number,
      sha: state.opts.reviewed_sha,
      state: "failed",
      failed_step: step_name,
      error: message,
      outcome: ledger_outcome(state),
      policy: if(settings, do: settings.merge_policy.ci)
    }

    root = Keyword.get(state.deps, :log_root, Path.expand("~/.aiur/logs/pr-merge"))

    case Keyword.get(state.deps, :append_record, &Record.append/2).(record, root) do
      :ok -> :ok
      {:error, reason} -> Logger.error("aiur pr merge: failure ledger write failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("aiur pr merge: failure ledger write failed: #{Exception.message(error)}")
  end

  defp redact_token(message) do
    Regex.replace(~r/(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})/, message, "[REDACTED]")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp current_stacktrace do
    case Process.info(self(), :current_stacktrace) do
      {:current_stacktrace, stacktrace} -> stacktrace
      _ -> []
    end
  end

  defp mark_merged_observed do
    state = run_state()
    Process.put({__MODULE__, :state}, %{state | merged_observed?: true})
  end

  defp failure_outcome(%{merged_observed?: true}), do: "GitHub confirms the PR is already merged"
  defp failure_outcome(%{delivered?: true}), do: "merge outcome may be unknown"
  defp failure_outcome(_state), do: "nothing was merged"

  defp ledger_outcome(%{merged_observed?: true}), do: "merged"
  defp ledger_outcome(%{delivered?: true}), do: "unknown"
  defp ledger_outcome(_state), do: "not_merged"

  defp failure_step(:record_setup), do: :record
  defp failure_step(step), do: step
end
