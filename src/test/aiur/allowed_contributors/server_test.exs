defmodule Aiur.AllowedContributors.ServerTest do
  use ExUnit.Case, async: true

  alias Aiur.AllowedContributors
  alias Aiur.AllowedContributorsFixture, as: Fixture

  @topic "ticket.101.issue.opened.allowed_contributor"

  defp audit_lines(server) do
    path = :sys.get_state(server).audit_path
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "an allowed individual's new issue publishes exactly one wake and audits the accept", context do
    {server, _gh} = Fixture.start(context, body: "user 42 # alice\n")

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:published, @topic, payload, opts}
    assert payload == %{action: "opened", author_id: 42, via: "user", allowlist_sha: Fixture.sha()}
    refute Map.has_key?(payload, :title) or Map.has_key?(payload, :body)
    assert opts[:bypass_contamination]

    assert [%{"decision" => "accept", "author_id" => 42, "allowlist_sha" => sha, "reason" => "user"}] = audit_lines(server)
    assert sha == Fixture.sha()

    # Seen again — by either producer — it is a duplicate, not a second wake.
    assert :duplicate = AllowedContributors.observe(Fixture.candidate(source: :poll), server)
    refute_received {:published, _, _, _}
  end

  test "an allowed org member's new issue publishes one wake naming the org", context do
    members = %{{"acme-org", "bob"} => Fixture.member(77, 43)}
    {server, _gh} = Fixture.start(context, body: "org 77 acme-org\n", members: members)

    assert {:accept, "org:77"} = AllowedContributors.observe(Fixture.candidate(author_id: 43, author_login: "bob"), server)
    assert_received {:published, @topic, %{via: "org:77", author_id: 43}, _opts}
  end

  test "a non-allowed author gets no wake and a logged rejection", context do
    {server, _gh} = Fixture.start(context, body: "user 42\n")

    assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(author_id: 666, author_login: "mallory"), server)
    refute_received {:published, _, _, _}
    assert [%{"decision" => "reject", "author_id" => 666, "reason" => "not_allowed"}] = audit_lines(server)
  end

  test "no file on the default branch admits nobody", context do
    {server, _gh} = Fixture.start(context, body: :absent)
    assert {:reject, :allowlist_absent} = AllowedContributors.observe(Fixture.candidate(), server)
    refute_received {:published, _, _, _}
  end

  test "a malformed file admits nobody and alerts once per commit", context do
    {server, _gh} = Fixture.start(context, body: "user 42\nalice\n")

    assert {:reject, :allowlist_invalid} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:alert, "allowed_contributors.invalid", _message}
    :ok = AllowedContributors.refresh(server)
    refute_received {:alert, _, _}
  end

  test "an unreadable allow-list defers without remembering the issue, then accepts once readable", context do
    {server, gh} = Fixture.start(context, body: {:error, :timeout})

    assert {:deferred, :allowlist_unavailable} = AllowedContributors.observe(Fixture.candidate(), server)
    refute_received {:published, _, _, _}

    # Still inside the on-demand retry window: no new read, still deferred.
    Agent.update(gh, &%{&1 | body: "user 42\n"})
    assert {:deferred, :allowlist_unavailable} = AllowedContributors.observe(Fixture.candidate(), server)

    Fixture.advance(gh, 60_000)
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
  end

  test "a merged change to the file alerts with the diff; an unchanged refresh does not", context do
    {server, gh} = Fixture.start(context, body: "user 42\n")
    _ = :sys.get_state(server)
    assert_received {:alert, "allowed_contributors.changed", first}
    assert first =~ "user:42"

    :ok = AllowedContributors.refresh(server)
    refute_received {:alert, _, _}

    Agent.update(gh, &%{&1 | body: "user 42\nuser 43\n"})
    :ok = AllowedContributors.refresh(server)
    assert_received {:alert, "allowed_contributors.changed", message}
    assert message =~ ~s(added ["user:43"])
  end

  test "the seen set survives a restart", context do
    dir = Path.join(System.tmp_dir!(), "aiur-ac-restart-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    {server, _gh} = Fixture.start(context, state_dir: dir, id: :first_boot)
    assert {:accept, _} = AllowedContributors.observe(Fixture.candidate(), server)
    stop_supervised!(:first_boot)

    {again, _gh} = Fixture.start(context, state_dir: dir)
    assert :duplicate = AllowedContributors.observe(Fixture.candidate(source: :poll), again)
  end

  test "revoking an entry on the default branch stops admitting that author at the next refresh", context do
    {server, gh} = Fixture.start(context, body: "user 42\nuser 43\n")
    _ = :sys.get_state(server)
    assert_received {:alert, "allowed_contributors.changed", _first_load}
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 1), server)

    Agent.update(gh, &%{&1 | body: "user 43\n"})
    :ok = AllowedContributors.refresh(server)
    assert_received {:alert, "allowed_contributors.changed", message}
    assert message =~ ~s(removed ["user:42"])

    assert {:reject, :not_allowed} = AllowedContributors.observe(Fixture.candidate(number: 2), server)
  end

  test "a failed refresh keeps the last good allow-list rather than flipping trust", context do
    {server, gh} = Fixture.start(context, body: "user 42\n")
    _ = :sys.get_state(server)
    Agent.update(gh, &%{&1 | body: {:error, :timeout}})
    :ok = AllowedContributors.refresh(server)

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
  end

  test "a wake that fails to publish is deferred and retried, never audited as accepted", context do
    test = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    publish = fn topic, _payload, _opts ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> {:error, :executor_namespace_rejects_github_source}
        _n -> send(test, {:published, topic}) && {:ok, 7, 1}
      end
    end

    {server, _gh} = Fixture.start(context, body: "user 42\n", publish_fun: publish)

    assert {:deferred, {:publish_failed, _}} = AllowedContributors.observe(Fixture.candidate(), server)
    refute_received {:published, _}
    assert [%{"decision" => "deferred"}] = audit_lines(server)

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(source: :poll), server)
    assert_received {:published, @topic}
  end

  test "a wake published while no Executor listener is bound is deferred, not lost", context do
    {server, _gh} = Fixture.start(context, body: "user 42\n", publish_fun: fn _topic, _payload, _opts -> {:ok, 9, 0} end)

    assert {:deferred, {:publish_failed, :no_subscribers}} = AllowedContributors.observe(Fixture.candidate(), server)
    # Not remembered, so the next sighting tries again.
    refute :duplicate == AllowedContributors.observe(Fixture.candidate(source: :poll), server)
  end

  # Independent review of #2958: the rate slot was taken before the publish,
  # so every deferred retry of one undelivered wake spent the author's hourly
  # budget, and after `rate_limit` retries the issue was rejected
  # `:rate_limited` and marked seen — lost for good.
  test "a wake that fails to publish does not spend the author's hourly budget", context do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    publish = fn _topic, _payload, _opts ->
      if Agent.get_and_update(attempts, &{&1, &1 + 1}) < 3, do: {:ok, 9, 0}, else: {:ok, 9, 1}
    end

    {server, _gh} = Fixture.start(context, body: "user 42\n", rate_limit: 2, publish_fun: publish)

    for _attempt <- 1..3 do
      assert {:deferred, {:publish_failed, :no_subscribers}} =
               AllowedContributors.observe(Fixture.candidate(source: :poll), server)
    end

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(source: :poll), server)
  end

  # Independent review of #2958: the wake carried a Publisher `dedup_key`,
  # which the Publisher records before it knows whether anyone received the
  # event. The retry of a zero-subscriber wake then came back `:deduped`, and
  # intake audited an accept and marked the issue seen for a wake nobody got.
  test "a retried wake is never counted as delivered on the Publisher's dedup answer", context do
    test = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    publish = fn _topic, _payload, opts ->
      send(test, {:publish_opts, opts})
      if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0, do: {:ok, 9, 0}, else: :deduped
    end

    {server, _gh} = Fixture.start(context, body: "user 42\n", publish_fun: publish)

    assert {:deferred, {:publish_failed, :no_subscribers}} = AllowedContributors.observe(Fixture.candidate(), server)
    assert_received {:publish_opts, opts}
    refute Keyword.has_key?(opts, :dedup_key)

    refute match?({:accept, _}, AllowedContributors.observe(Fixture.candidate(source: :poll), server))
    refute Enum.any?(audit_lines(server), &(&1["decision"] == "accept"))
  end

  test "an unwritable state directory never crashes intake", context do
    blocker = Path.join(System.tmp_dir!(), "aiur-ac-blocker-#{System.unique_integer([:positive])}")
    File.write!(blocker, "not a directory")
    on_exit(fn -> File.rm(blocker) end)

    {server, _gh} = Fixture.start(context, state_dir: Path.join(blocker, "state"))

    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(), server)
    assert Process.alive?(server)
    # The in-memory seen set stays authoritative for the process lifetime.
    assert :duplicate = AllowedContributors.observe(Fixture.candidate(source: :poll), server)
  end

  test "the per-author hourly cap survives a daemon restart", context do
    dir = Path.join(System.tmp_dir!(), "aiur-ac-rate-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    {server, _gh} = Fixture.start(context, state_dir: dir, rate_limit: 2, id: :rate_first_boot)
    for n <- 1..2, do: assert({:accept, _} = AllowedContributors.observe(Fixture.candidate(number: n), server))
    stop_supervised!(:rate_first_boot)

    {again, _gh} = Fixture.start(context, state_dir: dir, rate_limit: 2)
    assert {:reject, :rate_limited} = AllowedContributors.observe(Fixture.candidate(number: 3), again)
  end

  test "the rate limit caps accepted wakes per author per hour", context do
    {server, gh} = Fixture.start(context, body: "user 42\nuser 50\n", rate_limit: 2)

    outcomes = for n <- 1..4, do: AllowedContributors.observe(Fixture.candidate(number: n), server)
    assert outcomes == [{:accept, "user"}, {:accept, "user"}, {:reject, :rate_limited}, {:reject, :rate_limited}]

    # Another allowed author is unaffected.
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 9, author_id: 50), server)

    # The window rolls.
    Fixture.advance(gh, 3_600_001)
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 10), server)
  end
end
