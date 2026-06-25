defmodule Aiur.Events.LsRemoteTickerTest do
  @moduledoc """
  Bootstrap behavior: the first tick records SHAs without publishing
  (avoids a phantom-push storm on startup). Subsequent ticks publish a
  branch.push for any ref whose SHA changed AND for any brand-new ref.
  """

  use ExUnit.Case, async: false

  alias Aiur.Events.LsRemoteTicker

  setup do
    parent = self()

    publisher = fn topic, payload, opts ->
      send(parent, {:published, topic, payload, opts})
      {:ok, %{id: 1, subscribers: 0}}
    end

    %{publisher: publisher}
  end

  defp ls_remote_returning(refs) do
    fn _remote, _patterns -> {:ok, refs} end
  end

  # Drive one tick and block until the GenServer has finished handling
  # it. The `:polled` and `:published` sends both happen synchronously
  # inside `handle_info(:tick, ...)`, so a `:sys.get_state/1` call —
  # which queues behind `:tick` in the same FIFO mailbox — returns only
  # after the tick's messages are already in this process's mailbox.
  # This replaces the time-based `assert_receive ..., 500` waits, which
  # flaked under full-suite CI scheduler contention (#459): the messages
  # were never lost, only delivered late.
  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
    :ok
  end

  test "first tick records SHAs without publishing", %{publisher: publisher} do
    ls_remote_fun = ls_remote_returning(%{"refs/heads/aiur/99" => "sha1"})

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    refute_receive {:published, _topic, _payload, _opts}, 100
  end

  test "second tick publishes when a known SHA changes", %{publisher: publisher} do
    parent = self()

    ref_a = "refs/heads/aiur/99"
    ref_b = "refs/heads/aiur/100"

    {:ok, agent} = Agent.start_link(fn -> %{ref_a => "sha1", ref_b => "shaA"} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      {:ok, Agent.get(agent, & &1)}
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    # Bootstrap tick.
    tick(pid)
    assert_receive :polled, 500

    # SHA for aiur/99 changes; aiur/100 stays.
    Agent.update(agent, fn _ -> %{ref_a => "sha2", ref_b => "shaA"} end)
    tick(pid)
    assert_receive :polled, 500

    assert_receive {:published, "ticket.99.branch.push", payload, opts}, 500
    assert payload.ref == ref_a
    assert payload.sha == "sha2"
    assert payload.repo == "owner/aiur"
    assert opts[:issue_number] == "99"
    assert opts[:dedup_key] == {"owner/aiur", ref_a, "sha2"}

    refute_receive {:published, "ticket.100.branch.push", _, _}, 100
  end

  test "second tick publishes for a brand-new ref appearing", %{publisher: publisher} do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> %{} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      {:ok, Agent.get(agent, & &1)}
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    assert_receive :polled, 2_000

    Agent.update(agent, fn _ -> %{"refs/heads/aiur/101" => "newsha"} end)
    tick(pid)
    assert_receive :polled, 2_000

    assert_receive {:published, "ticket.101.branch.push", _, _}, 2_000
  end

  test "non-canonical aiur/<id>-<slug> branches do NOT route to ticket.<id>.branch.push",
       %{publisher: publisher} do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> {:ok, %{}} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      Agent.get(agent, & &1)
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    assert_receive :polled, 500

    # The branch-name lock in the using-aiur skill's dev-loop.md keeps
    # agents on canonical aiur/<id>. If they invent a workaround
    # branch (aiur/99-pr, aiur/99-test-fixture, aiur/99/sub) the
    # regex must NOT route those to ticket.99 — a dev push to a
    # fixture branch would otherwise falsely wake blockees waiting
    # on the real ticket's work.
    Agent.update(agent, fn _ ->
      {:ok,
       %{
         "refs/heads/aiur/99-pr" => "sha-pr",
         "refs/heads/aiur/99-test-fixture" => "sha-fixture",
         "refs/heads/aiur/99/sub" => "sha-sub",
         "refs/heads/aiur/99_v2" => "sha-v2"
       }}
    end)

    tick(pid)
    assert_receive :polled, 500

    refute_receive {:published, "ticket.99.branch.push", _, _}, 200
    refute_receive {:published, "ticket." <> _, _, _}, 100
  end

  test "non-numeric branch suffix (aiur/abc) is NOT treated as a ticket push",
       %{publisher: publisher} do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> {:ok, %{}} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      Agent.get(agent, & &1)
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    assert_receive :polled, 500

    Agent.update(agent, fn _ -> {:ok, %{"refs/heads/aiur/abc" => "shaA"}} end)
    tick(pid)
    assert_receive :polled, 500

    refute_receive {:published, "ticket." <> _rest, _, _}, 200
  end

  test "system branch (non-aiur ref) publishes to system.<branch>.branch.push", %{
    publisher: publisher
  } do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> %{"refs/heads/main" => "shaA"} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      {:ok, Agent.get(agent, & &1)}
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        ref_pattern: "refs/heads/main",
        start_paused?: true
      )

    tick(pid)
    assert_receive :polled, 500

    Agent.update(agent, fn _ -> %{"refs/heads/main" => "shaB"} end)
    tick(pid)
    assert_receive :polled, 500

    assert_receive {:published, "system.main.branch.push", _, opts}, 500
    refute Keyword.has_key?(opts, :issue_number)
  end

  test "ls-remote error preserves cache and does not crash", %{publisher: publisher} do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> {:ok, %{"refs/heads/aiur/99" => "sha1"}} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      Agent.get(agent, & &1)
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    # Bootstrap.
    tick(pid)
    assert_receive :polled, 500

    # Now flip to error response.
    Agent.update(agent, fn _ -> {:error, :git_ls_remote_failed} end)
    tick(pid)
    assert_receive :polled, 500
    assert Process.alive?(pid)

    # Recover: success again with a changed SHA → publish fires.
    Agent.update(agent, fn _ -> {:ok, %{"refs/heads/aiur/99" => "sha2"}} end)
    tick(pid)
    assert_receive :polled, 500
    assert_receive {:published, "ticket.99.branch.push", _, _}, 500
  end

  test "first tick errors, then second tick succeeds → bootstrap on the success, no phantom publishes",
       %{publisher: publisher} do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> {:error, :git_ls_remote_failed} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      Agent.get(agent, & &1)
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    # Tick 1 errors. `bootstrapped?` must STAY false. The previous
    # behavior of marking bootstrapped on error caused tick 2 to
    # treat every existing aiur/* ref as a new push and fan-out
    # phantom auto-resumes for every paused blockee. The lost-push
    # window between an error and the next success is recovered by
    # the firehose as the second detection source.
    tick(pid)
    assert_receive :polled, 500

    # Tick 2 succeeds with multiple refs that LOOK new because the
    # cache is still empty. Bootstrap fires — refs are recorded but
    # NOT published.
    Agent.update(agent, fn _ ->
      {:ok,
       %{
         "refs/heads/aiur/99" => "sha-99",
         "refs/heads/aiur/100" => "sha-100",
         "refs/heads/aiur/101" => "sha-101"
       }}
    end)

    tick(pid)
    assert_receive :polled, 500
    refute_receive {:published, _topic, _payload, _opts}, 200

    # Tick 3 with a CHANGED ref on aiur/99 publishes exactly one push.
    Agent.update(agent, fn _ ->
      {:ok,
       %{
         "refs/heads/aiur/99" => "sha-99-changed",
         "refs/heads/aiur/100" => "sha-100",
         "refs/heads/aiur/101" => "sha-101"
       }}
    end)

    tick(pid)
    assert_receive :polled, 500
    assert_receive {:published, "ticket.99.branch.push", _, _}, 500
    refute_receive {:published, "ticket.100.branch.push", _, _}, 100
    refute_receive {:published, "ticket.101.branch.push", _, _}, 100
  end

  test "empty-string repo → dedup_key is omitted from publish opts (no Publisher crash)",
       %{publisher: publisher} do
    parent = self()

    {:ok, agent} = Agent.start_link(fn -> {:ok, %{}} end)

    ls_remote_fun = fn _remote, _patterns ->
      send(parent, :polled)
      Agent.get(agent, & &1)
    end

    # `repo: ""` exercises the same `not is_binary or empty` branch as
    # `repo: nil` would, without relying on `Aiur.Tracker.project_identity/0`
    # returning nil in the test environment.
    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "",
        start_paused?: true
      )

    tick(pid)
    assert_receive :polled, 500

    Agent.update(agent, fn _ -> {:ok, %{"refs/heads/aiur/99" => "sha1"}} end)
    tick(pid)
    assert_receive :polled, 500

    assert_receive {:published, "ticket.99.branch.push", _, opts}, 500

    refute Keyword.has_key?(opts, :dedup_key),
           "dedup_key must be omitted when repo is empty/nil so Publisher.deduped? does not see a malformed key"
  end

  test "a DNS ls-remote failure builds a classified streak toward operator escalation",
       %{publisher: publisher} do
    # WHY (#617): the operator-visible symptom was `git ls-remote` failing
    # with "Could not resolve host: github.com". That output must classify as
    # :dns and accumulate a streak so a sustained outage escalates rather than
    # only Logger.debug-ing forever.
    dns_failure = fn _remote, _patterns ->
      {:error, {:git_ls_remote_failed, 128, "fatal: Could not resolve host: github.com"}}
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: dns_failure,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    state1 = :sys.get_state(pid)
    assert state1.connectivity[:ls_remote] == {:dns, 1}
    assert state1.next_delay_ms == 1_000

    tick(pid)
    state2 = :sys.get_state(pid)
    assert {:dns, 2} = state2.connectivity[:ls_remote]
    assert state2.next_delay_ms == 2_000
  end

  test "a timeout ls-remote failure backs off the next tick exponentially", %{
    publisher: publisher
  } do
    timeout_failure = fn _remote, _patterns ->
      {:error, {:git_ls_remote_failed, 128, "fatal: operation timed out"}}
    end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: timeout_failure,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    assert :sys.get_state(pid).next_delay_ms == 1_000

    tick(pid)
    assert :sys.get_state(pid).next_delay_ms == 2_000
  end

  test "a successful tick clears the connectivity streak", %{publisher: publisher} do
    {:ok, agent} =
      Agent.start_link(fn -> {:error, {:git_ls_remote_failed, 128, "Could not resolve host"}} end)

    ls_remote_fun = fn _remote, _patterns -> Agent.get(agent, & &1) end

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        commits_fun: fn _repo, _sha -> [] end,
        repo: "owner/aiur",
        start_paused?: true
      )

    tick(pid)
    assert {:dns, 1} = :sys.get_state(pid).connectivity[:ls_remote]
    assert :sys.get_state(pid).next_delay_ms == 1_000

    Agent.update(agent, fn _ -> {:ok, %{}} end)
    tick(pid)
    state = :sys.get_state(pid)
    assert state.connectivity[:ls_remote] == nil
    assert state.next_delay_ms == state.interval_ms
  end
end
