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

    Agent.update(gh, &%{&1 | mono: 60_000})
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

  test "the rate limit caps accepted wakes per author per hour", context do
    {server, gh} = Fixture.start(context, body: "user 42\nuser 50\n", rate_limit: 2)

    outcomes = for n <- 1..4, do: AllowedContributors.observe(Fixture.candidate(number: n), server)
    assert outcomes == [{:accept, "user"}, {:accept, "user"}, {:reject, :rate_limited}, {:reject, :rate_limited}]

    # Another allowed author is unaffected.
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 9, author_id: 50), server)

    # The window rolls.
    Agent.update(gh, &%{&1 | mono: 3_600_001})
    assert {:accept, "user"} = AllowedContributors.observe(Fixture.candidate(number: 10), server)
  end
end
