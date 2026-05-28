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

  test "first tick records SHAs without publishing", %{publisher: publisher} do
    ls_remote_fun = ls_remote_returning(%{"refs/heads/aiur/99" => "sha1"})

    {:ok, pid} =
      LsRemoteTicker.start_link(
        name: nil,
        ls_remote_fun: ls_remote_fun,
        publisher: publisher,
        repo: "owner/aiur",
        start_paused?: true
      )

    send(pid, :tick)
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
        repo: "owner/aiur",
        start_paused?: true
      )

    # Bootstrap tick.
    send(pid, :tick)
    assert_receive :polled, 500

    # SHA for aiur/99 changes; aiur/100 stays.
    Agent.update(agent, fn _ -> %{ref_a => "sha2", ref_b => "shaA"} end)
    send(pid, :tick)
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
        repo: "owner/aiur",
        start_paused?: true
      )

    send(pid, :tick)
    assert_receive :polled, 500

    Agent.update(agent, fn _ -> %{"refs/heads/aiur/101" => "newsha"} end)
    send(pid, :tick)
    assert_receive :polled, 500

    assert_receive {:published, "ticket.101.branch.push", _, _}, 500
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
        repo: "owner/aiur",
        ref_pattern: "refs/heads/main",
        start_paused?: true
      )

    send(pid, :tick)
    assert_receive :polled, 500

    Agent.update(agent, fn _ -> %{"refs/heads/main" => "shaB"} end)
    send(pid, :tick)
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
        repo: "owner/aiur",
        start_paused?: true
      )

    # Bootstrap.
    send(pid, :tick)
    assert_receive :polled, 500

    # Now flip to error response.
    Agent.update(agent, fn _ -> {:error, :git_ls_remote_failed} end)
    send(pid, :tick)
    assert_receive :polled, 500
    assert Process.alive?(pid)

    # Recover: success again with a changed SHA → publish fires.
    Agent.update(agent, fn _ -> {:ok, %{"refs/heads/aiur/99" => "sha2"}} end)
    send(pid, :tick)
    assert_receive :polled, 500
    assert_receive {:published, "ticket.99.branch.push", _, _}, 500
  end
end
