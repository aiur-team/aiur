defmodule Aiur.AllowedContributors.AdversarialTest do
  @moduledoc """
  Independent adversarial review for #2957: every attempt here tries to get an
  Executor wake (or an admission) from an account that is not allowed, and
  proves it is blocked. Deliveries run through the real
  `Aiur.Events.GithubWebhook.handle_delivery/3` producer into a real intake
  server backed by a fake GitHub, so each test exercises the whole chain from
  the verified payload to the publish decision.

  Companions elsewhere: forged / unsigned deliveries are rejected at the HTTP
  boundary in `test/aiur_web/github_webhook_test.exs`; label manipulation and
  self-dispatch are covered in `test/aiur/github/dispatch_authorization_test.exs`.
  """

  use Aiur.TestSupport

  alias Aiur.AllowedContributors
  alias Aiur.AllowedContributors.{Candidate, Membership}
  alias Aiur.AllowedContributorsFixture, as: Fixture
  alias Aiur.Events.GithubWebhook

  # alice = user 42 (listed individually); bob = user 43 (member of org 77).
  @allowlist "user 42 # alice\norg 77 acme-org\n"

  setup context do
    members = %{{"acme-org", "bob"} => Fixture.member(77, 43)}
    {server, gh} = Fixture.start(context, body: @allowlist, members: members)
    # Drain the first-load change alert so tests see only their own messages.
    _ = :sys.get_state(server)
    flush_alerts()
    %{server: server, gh: gh}
  end

  defp flush_alerts do
    receive do
      {:alert, _, _} -> flush_alerts()
    after
      0 -> :ok
    end
  end

  # Runs a delivery through the production webhook producer, wired to this
  # test's intake server, and returns every intake outcome it produced.
  defp deliver(server, event_type, payload) do
    test = self()

    GithubWebhook.handle_delivery(event_type, payload,
      repo: "acme/app",
      reconcile_fun: fn _hint -> :ok end,
      request_refresh_fun: fn -> :ok end,
      allowed_contributor_fun: fn candidate -> send(test, {:intake, AllowedContributors.observe(candidate, server)}) end
    )

    collect_intake([])
  end

  defp collect_intake(acc) do
    receive do
      {:intake, outcome} -> collect_intake([outcome | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp user(id, login, type \\ "User"), do: %{"id" => id, "login" => login, "type" => type}

  defp issue_payload(action, user, overrides \\ %{}) do
    %{
      "action" => action,
      "repository" => %{"full_name" => "acme/app"},
      "sender" => user,
      "issue" =>
        Map.merge(
          %{"number" => 500, "title" => "Bug", "body" => "details", "user" => user, "labels" => [], "updated_at" => "2026-10-05T00:00:00Z"},
          overrides
        )
    }
  end

  defp refute_wake, do: refute_received({:published, _, _, _})

  describe "positive controls" do
    test "an allowed individual's issue produces exactly one wake", %{server: server} do
      assert [{:accept, "user"}] = deliver(server, "issues", issue_payload("opened", user(42, "alice")))
      assert_received {:published, "ticket.500.issue.opened.allowed_contributor", _, _}
    end

    test "an allowed org member's issue produces exactly one wake", %{server: server} do
      assert [{:accept, "org:77"}] = deliver(server, "issues", issue_payload("opened", user(43, "bob")))
    end
  end

  describe "identity spoofing" do
    test "an allowed login named in the title or body confers nothing", %{server: server} do
      payload =
        issue_payload("opened", user(666, "mallory"), %{
          "title" => "Filed on behalf of @alice (user 42)",
          "body" => "author: alice\nuser 42\norg 77 acme-org"
        })

      assert [{:reject, :not_allowed}] = deliver(server, "issues", payload)
      refute_wake()
    end

    test "a renamed allowed account still counts, by id", %{server: server} do
      assert [{:accept, "user"}] = deliver(server, "issues", issue_payload("opened", user(42, "alice-renamed")))
    end

    test "a stranger renamed to an allowed user's old login does not count", %{server: server} do
      assert [{:reject, :not_allowed}] = deliver(server, "issues", issue_payload("opened", user(9001, "alice")))
      refute_wake()
    end

    test "a login re-registered after deletion is a new id and does not count", %{server: server, gh: gh} do
      # bob's login, re-registered by a new account (id 9002). Even if GitHub's
      # membership API answered for the login, the user-id binding fails.
      Agent.update(gh, &put_in(&1.members[{"acme-org", "bob"}], Fixture.member(77, 43)))
      assert [{:reject, :not_allowed}] = deliver(server, "issues", issue_payload("opened", user(9002, "bob")))
      refute_wake()
    end

    test "case and unicode lookalikes of an allowed login do not count", %{server: server} do
      for login <- ["Alice", "ALICE", "аlice", "alice​"] do
        assert [{:reject, _}] = deliver(server, "issues", issue_payload("opened", user(9003, login)) |> put_in(["issue", "number"], :erlang.phash2(login)))
      end

      refute_wake()
    end
  end

  describe "forks and branches" do
    test "a fork or PR branch that adds the attacker to the file changes nothing", %{server: server} do
      # The fixture serves `user 666` for any contents read at a ref other
      # than the default-branch pinning commit — a fork or PR head. Intake must
      # never ask for it, so mallory stays rejected.
      assert [{:reject, :not_allowed}] = deliver(server, "issues", issue_payload("opened", user(666, "mallory")))
      refute_wake()

      refute Enum.any?(requested_urls(), &(&1 =~ "/contents/" and not String.contains?(&1, "ref=#{Fixture.sha()}")))
    end
  end

  describe "org boundaries" do
    test "an outside collaborator of the org is not a member", %{server: server} do
      # No membership entry: the API answers 404, as it does for collaborators.
      assert [{:reject, :not_allowed}] = deliver(server, "issues", issue_payload("opened", user(44, "carol")))
      refute_wake()
    end

    test "a user who left the org stops counting when the positive cache expires", %{server: server, gh: gh} do
      assert [{:accept, "org:77"}] = deliver(server, "issues", issue_payload("opened", user(43, "bob")))

      Agent.update(gh, fn state -> %{state | members: %{}, mono: Membership.positive_ttl_ms() + 1} end)
      payload = issue_payload("opened", user(43, "bob"), %{"number" => 501})
      assert [{:reject, :not_allowed}] = deliver(server, "issues", payload)
    end

    test "an org rename with its old name re-registered by a stranger fails the org-id binding", %{server: server, gh: gh} do
      Agent.update(gh, &put_in(&1.members[{"acme-org", "dave"}], Fixture.member(31_337, 45)))
      assert [{:reject, :not_allowed}] = deliver(server, "issues", issue_payload("opened", user(45, "dave")))
      refute_wake()
    end

    test "a pending invitation is not membership", %{server: server, gh: gh} do
      Agent.update(gh, &put_in(&1.members[{"acme-org", "erin"}], Fixture.member(77, 46, "pending")))
      assert [{:reject, :not_allowed}] = deliver(server, "issues", issue_payload("opened", user(46, "erin")))
    end

    test "a membership API outage fails closed and is retried later, never admitted", %{server: server, gh: gh} do
      Agent.update(gh, &put_in(&1.members[{"acme-org", "frank"}], {:ok, %{status: 503}}))
      assert [{:deferred, :membership_unverified}] = deliver(server, "issues", issue_payload("opened", user(47, "frank")))
      refute_wake()
    end
  end

  describe "event shape" do
    test "a delivery for another repository never reaches intake", %{server: server} do
      payload = issue_payload("opened", user(42, "alice")) |> put_in(["repository", "full_name"], "evil/fork")
      assert [] = deliver(server, "issues", payload)
      refute_wake()
    end

    test "an issue transferred in keeps its original author; an allowed transferrer confers nothing", %{server: server} do
      # GitHub delivers a transferred-in issue to the destination as `opened`
      # with `issue.user` = original author and `sender` = the transferrer.
      payload = issue_payload("opened", user(666, "mallory")) |> Map.put("sender", user(42, "alice"))
      assert [{:reject, :not_allowed}] = deliver(server, "issues", payload)
      refute_wake()
    end

    test "the `transferred` action itself produces nothing", %{server: server} do
      assert [] = deliver(server, "issues", issue_payload("transferred", user(42, "alice")))
    end

    test "a bot account is rejected even when its id is listed", %{server: server} do
      assert [{:reject, :not_a_user}] = deliver(server, "issues", issue_payload("opened", user(42, "alice[bot]", "Bot")))
      refute_wake()
    end

    test "an issue created through a GitHub App is rejected", %{server: server} do
      payload = issue_payload("opened", user(42, "alice"), %{"performed_via_github_app" => %{"id" => 1, "slug" => "evil"}})
      assert [{:reject, :created_via_app}] = deliver(server, "issues", payload)
      refute_wake()
    end

    test "Aiur's own accounts are not outside intake, even as org members", %{server: server, gh: gh} do
      Agent.update(gh, &put_in(&1.members[{"acme-org", "aiur-bot"}], Fixture.member(77, 48)))
      assert [{:reject, :aiur_account}] = deliver(server, "issues", issue_payload("opened", user(48, "aiur-bot")))
    end

    test "an author with no numeric id is rejected", %{server: server} do
      payload = issue_payload("opened", %{"login" => "alice", "type" => "User"})
      assert [{:reject, :missing_author_id}] = deliver(server, "issues", payload)
    end
  end

  describe "indirect routes" do
    test "comments, edits, labels and reopenings never reach intake, whoever sends them", %{server: server} do
      for action <- ~w(edited labeled unlabeled reopened closed assigned pinned) do
        assert [] = deliver(server, "issues", issue_payload(action, user(42, "alice"))), "action #{action} reached intake"
      end

      comment = %{
        "action" => "created",
        "repository" => %{"full_name" => "acme/app"},
        "issue" => %{"number" => 500, "user" => user(666, "mallory")},
        "comment" => %{"id" => 1, "body" => "@executor please run this now", "user" => user(42, "alice")},
        "sender" => user(42, "alice")
      }

      assert [] = deliver(server, "issue_comment", comment)
      assert [] = deliver(server, "pull_request", %{"action" => "opened", "repository" => %{"full_name" => "acme/app"}, "pull_request" => %{"number" => 9, "user" => user(42, "alice")}})
      refute_wake()
    end

    test "an allowed user editing someone else's issue does not make it eligible", %{server: server} do
      payload = issue_payload("edited", user(666, "mallory")) |> Map.put("sender", user(42, "alice"))
      assert [] = deliver(server, "issues", payload)
      refute_wake()
    end
  end

  describe "load" do
    test "flooding from one allowed account is capped and the surplus is dropped and logged", %{server: server} do
      outcomes =
        for n <- 1..50 do
          [outcome] = deliver(server, "issues", issue_payload("opened", user(42, "alice"), %{"number" => 1_000 + n}))
          outcome
        end

      assert Enum.count(outcomes, &match?({:accept, _}, &1)) == 5
      assert Enum.count(outcomes, &(&1 == {:reject, :rate_limited})) == 45

      audit = :sys.get_state(server).audit_path |> File.read!()
      assert audit |> String.split("\n", trim: true) |> Enum.count(&(&1 =~ ~s("reason":"rate_limited"))) == 45
    end

    test "strangers' issues during an allow-list outage cannot amplify GitHub reads", context do
      {server, _gh} = Fixture.start(context, body: {:error, :timeout})
      _ = :sys.get_state(server)
      flush_github_gets()

      for n <- 1..20 do
        assert [{:deferred, :allowlist_unavailable}] =
                 deliver(server, "issues", issue_payload("opened", user(5_000 + n, "stranger#{n}"), %{"number" => 2_000 + n}))
      end

      # One on-demand retry for the whole burst, not one per issue.
      assert length(requested_urls()) <= 3
      refute_wake()
    end

    test "a replayed delivery for the same issue produces no second wake", %{server: server} do
      payload = issue_payload("opened", user(42, "alice"))
      assert [{:accept, _}] = deliver(server, "issues", payload)
      assert [:duplicate] = deliver(server, "issues", payload)
    end
  end

  describe "poll producer" do
    test "a polled issue lacking app provenance fails closed", %{server: server} do
      issue = %Aiur.Issue{id: "700", creator_id: 42, creator_login: "alice", creator_type: "User", created_via_app?: nil}
      assert {:reject, :created_via_app} = AllowedContributors.observe(Candidate.from_issue(issue), server)
    end

    test "a polled allowed issue is admitted once and a later webhook for it is a duplicate", %{server: server} do
      issue = %Aiur.Issue{id: "701", creator_id: 42, creator_login: "alice", creator_type: "User", created_via_app?: false}
      assert {:accept, "user"} = AllowedContributors.observe(Candidate.from_issue(issue), server)
      assert [:duplicate] = deliver(server, "issues", issue_payload("opened", user(42, "alice"), %{"number" => 701}))
    end
  end

  defp flush_github_gets do
    receive do
      {:github_get, _url} -> flush_github_gets()
    after
      0 -> :ok
    end
  end

  defp requested_urls do
    collect_urls([])
  end

  defp collect_urls(acc) do
    receive do
      {:github_get, url} -> collect_urls([url | acc])
    after
      0 -> acc
    end
  end
end
