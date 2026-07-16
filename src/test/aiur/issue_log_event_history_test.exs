defmodule Aiur.IssueLogEventHistoryTest do
  @moduledoc """
  Bootstrap-digest dependency: `Aiur.IssueLog.event_history/2` parses
  `[event:emit]` / `[event:emit_alert]` / `[event:self]` / `[event:consumed]`
  lines from the on-disk per-issue log into partial event maps. Used by
  `AgentRunner.maybe_enqueue_bootstrap_digest/1` to build the bootstrap
  digest of events missed while the agent was inactive.
  """

  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.TrackerIdentity

  setup do
    original_log_file = Application.get_env(:aiur, :log_file)
    identifier = "test-event-history-#{System.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), "aiur-event-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "log"))

    Application.put_env(:aiur, :log_file, Path.join(tmp, "log/aiur.log"))

    on_exit(fn ->
      case original_log_file do
        nil -> Application.delete_env(:aiur, :log_file)
        value -> Application.put_env(:aiur, :log_file, value)
      end

      File.rm_rf!(tmp)
    end)

    %{identifier: identifier, tmp: tmp}
  end

  defp write_log(identifier, lines) do
    path = Aiur.IssueLog.log_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  test "parses [event:emit] lines into {id, topic, kind, summary, ts}", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [event:emit] id=42 ticket.99.branch.push: push abc123",
      "2026-05-27T10:00:01Z [event:emit] id=43 ticket.99.pr.opened: PR #120 opened"
    ])

    events = Aiur.IssueLog.event_history(id)

    assert [
             %{id: 42, topic: "ticket.99.branch.push", kind: "emit", summary: "push abc123"},
             %{id: 43, topic: "ticket.99.pr.opened", kind: "emit", summary: "PR #120 opened"}
           ] = events
  end

  test "since_id filters out events at or below cursor", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [event:emit] id=10 ticket.99.branch.push: a",
      "2026-05-27T10:00:01Z [event:emit] id=15 ticket.99.branch.push: b",
      "2026-05-27T10:00:02Z [event:emit] id=20 ticket.99.branch.push: c"
    ])

    events = Aiur.IssueLog.event_history(id, since_id: 15)

    assert Enum.map(events, & &1.id) == [20]
  end

  test "default kinds excludes :consumed and :self", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [event:emit] id=1 ticket.99.branch.push: emit",
      "2026-05-27T10:00:01Z [event:consumed] id=2 ticket.99.branch.push: consumed",
      "2026-05-27T10:00:02Z [event:self] id=3 ticket.99.agent.progress: self",
      "2026-05-27T10:00:03Z [event:emit_alert] id=4 ticket.99.agent.attention: alert"
    ])

    events = Aiur.IssueLog.event_history(id)

    assert Enum.map(events, & &1.id) == [1, 4]
  end

  test "kinds opt overrides default filter", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [event:emit] id=1 t.a: x",
      "2026-05-27T10:00:01Z [event:consumed] id=2 t.b: y"
    ])

    events = Aiur.IssueLog.event_history(id, kinds: [:emit, :consumed])

    assert Enum.map(events, & &1.id) == [1, 2]
  end

  test "missing log file returns empty list", %{identifier: id} do
    assert Aiur.IssueLog.event_history(id) == []
  end

  test "typed reads distinguish missing, unavailable, and genuinely empty history", %{tmp: tmp} do
    identity = identity()
    path = Aiur.IssueLog.log_path(identity)

    assert {:error, :missing_source} = Aiur.IssueLog.event_history(identity)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    assert {:ok, []} = Aiur.IssueLog.event_history(identity)

    File.rm!(path)
    File.mkdir_p!(path)

    assert {:error, {:unavailable, :eisdir}} = Aiur.IssueLog.event_history(identity)
    assert String.starts_with?(path, Path.join(tmp, "log"))
  end

  test "typed paths keep equal repository leaves isolated by owner" do
    alice = identity(owner: "alice", repository: "project")
    bob = identity(owner: "bob", repository: "project")

    alice_path = Aiur.IssueLog.log_path(alice)
    bob_path = Aiur.IssueLog.log_path(bob)

    refute alice_path == bob_path

    File.mkdir_p!(Path.dirname(alice_path))

    File.write!(
      alice_path,
      "2026-07-15T12:00:00Z [event:emit] id=7 ticket.42.pr.opened: private repository event\n"
    )

    assert {:ok, [%{id: 7}]} = Aiur.IssueLog.event_history(alice)
    assert {:error, :missing_source} = Aiur.IssueLog.event_history(bob)
  end

  test "legacy writers and typed readers resolve the same configured repository path" do
    assert {:ok, {owner, repository}} = GitHubConfig.configured_repo()
    identity = identity(owner: owner, repository: repository)

    assert Aiur.IssueLog.log_path(identity.identifier) == Aiur.IssueLog.log_path(identity)
  end

  test "lines without [event:*] tag are ignored", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [agent] (#99) some agent message",
      "2026-05-27T10:00:01Z [cmd] gh issue view 99",
      "2026-05-27T10:00:02Z [event:emit] id=99 ticket.99.branch.push: push xyz"
    ])

    events = Aiur.IssueLog.event_history(id)

    assert [%{id: 99, topic: "ticket.99.branch.push"}] = events
  end

  test "event without summary still parses", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [event:emit] id=5 ticket.99.branch.push"
    ])

    events = Aiur.IssueLog.event_history(id)

    assert [%{id: 5, topic: "ticket.99.branch.push", summary: ""}] = events
  end

  test "parses src= and trust= flags into typed event fields", %{identifier: id} do
    write_log(id, [
      "2026-05-27T10:00:00Z [event:emit] id=7 src=github trust=true ticket.99.issue.commented: comment body",
      "2026-05-27T10:00:01Z [event:emit] id=8 src=github trust=false ticket.99.issue.commented: comment body",
      "2026-05-27T10:00:02Z [event:emit] id=9 ticket.99.branch.push: push abc"
    ])

    events = Aiur.IssueLog.event_history(id)

    assert [
             %{id: 7, source: :github, author_trusted?: true},
             %{id: 8, source: :github, author_trusted?: false},
             %{id: 9, source: nil, author_trusted?: nil}
           ] = events
  end

  defp identity(opts \\ []) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: Keyword.get(opts, :owner, "owner"),
      repository: Keyword.get(opts, :repository, "repo"),
      provider_id: "I-42",
      identifier: "42",
      reason: nil
    }
  end
end
