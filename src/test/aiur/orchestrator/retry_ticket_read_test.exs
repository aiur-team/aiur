defmodule Aiur.Orchestrator.RetryTicketReadTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.{Config, DispatchAuthorization, Issues}
  alias Aiur.Orchestrator.{RetryEngine, State}
  alias Aiur.WorkflowStore

  setup do
    root = Path.join(System.tmp_dir!(), "retry-ticket-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "config")
    File.write!(path, "tracker:\n  kind: github\n  active_states: [todo, in-progress]\n  github:\n    repo: owner/repo\n    allowed_users: [trusted]\n")
    previous = Application.fetch_env(:aiur, :workflow_file_path)
    token = System.get_env("GITHUB_TOKEN")
    token_keys = [{Config, :resolved_token}, {Config, :resolved_token_source}]
    cached = Enum.map(token_keys, &{&1, :persistent_term.get(&1, :unset)})
    Application.put_env(:aiur, :workflow_file_path, path)
    System.put_env("GITHUB_TOKEN", "fixture-retry-token")
    Enum.each(token_keys, &:persistent_term.erase/1)
    DispatchAuthorization.clear_cache()
    reload_if_running()

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :workflow_file_path, value)
        :error -> Application.delete_env(:aiur, :workflow_file_path)
      end

      if token, do: System.put_env("GITHUB_TOKEN", token), else: System.delete_env("GITHUB_TOKEN")

      Enum.each(cached, fn
        {key, :unset} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)

      DispatchAuthorization.clear_cache()
      reload_if_running()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "a retry reads and authorizes only its own ticket, not the candidate backlog" do
    assert {:noreply, state} = retry()
    assert state.running["1"].pid == self()
    assert_received {:dispatched, %{id: "1", dispatch_authorization: :authorized}}
    assert requests() == ["/repos/owner/repo/issues/1", "/repos/owner/repo/issues/1/timeline"]
  end

  test "an outsider label remains denied without authorizing unrelated candidates" do
    assert {:noreply, state} = retry(actor: "outsider")
    refute MapSet.member?(state.claimed, "1")
    refute_received {:dispatched, _}
    assert requests() == ["/repos/owner/repo/issues/1", "/repos/owner/repo/issues/1/timeline"]
  end

  test "a paused ticket stays undispatched after the targeted read" do
    assert {:noreply, state} = retry(paused: true)
    refute MapSet.member?(state.claimed, "1")
    refute_received {:dispatched, _}
    assert requests() == ["/repos/owner/repo/issues/1", "/repos/owner/repo/issues/1/timeline"]
  end

  test "a missing retry ticket releases its claim after one read" do
    assert {:noreply, state} = retry(missing: true)
    refute MapSet.member?(state.claimed, "1")
    refute_received {:dispatched, _}
    assert requests() == ["/repos/owner/repo/issues/1"]
  end

  defp retry(opts \\ []) do
    request = fn request -> respond(request, opts) end

    RetryEngine.handle_retry_issue(
      %State{max_concurrent_agents: 2, effective_concurrent_agents: 2, claimed: MapSet.new(["1"])},
      "1",
      1,
      %{identifier: "1", worker_host: nil},
      ensure_tracker_preflight_fun: fn state -> {:ok, state} end,
      fetch_candidate_issues_fun: fn -> Issues.fetch_candidate_issues(request_fun: request) end,
      fetch_issue_states_by_ids_fun: fn ids -> Issues.fetch_issue_states_by_ids(ids, request_fun: request) end,
      dispatch_fun: fn state, issue, _attempt, _host, _opts ->
        send(self(), {:dispatched, issue})
        %{state | running: Map.put(state.running, issue.id, %{pid: self()})}
      end
    )
  end

  defp respond(request, opts) do
    path = URI.parse(request.url).path
    Process.put(:retry_read_requests, Process.get(:retry_read_requests, []) ++ [path])

    cond do
      path == "/repos/owner/repo/issues" ->
        numbers = if opts[:missing], do: 2..5, else: 1..5
        {:ok, %{status: 200, body: Enum.map(numbers, &issue(&1, opts))}}

      String.ends_with?(path, "/timeline") ->
        actor = if path == "/repos/owner/repo/issues/1/timeline", do: opts[:actor] || "trusted", else: "trusted"

        {:ok, %{status: 200, body: [%{"id" => 10, "event" => "labeled", "label" => %{"name" => "agent:todo"}, "actor" => %{"login" => actor}, "created_at" => "2026-01-01T00:00:00Z"}]}}

      path == "/repos/owner/repo/issues/1" ->
        if opts[:missing], do: {:ok, %{status: 404}}, else: {:ok, %{status: 200, body: issue(1, opts)}}

      true ->
        flunk("unexpected GitHub request: #{path}")
    end
  end

  defp issue(number, opts) do
    labels = [%{"name" => "agent:todo"}]
    labels = if number == 1 and opts[:paused], do: labels ++ [%{"name" => "agent:paused"}], else: labels
    %{"number" => number, "title" => "Ticket #{number}", "state" => "open", "labels" => labels, "updated_at" => "2026-01-01T00:00:00Z"}
  end

  defp requests, do: Process.get(:retry_read_requests, [])

  defp reload_if_running do
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()
  end
end
