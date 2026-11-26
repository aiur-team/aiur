defmodule Aiur.Events.GithubWebhookAttributionTest do
  use Aiur.TestSupport.WebhookTailCase

  alias Aiur.Events.{Exchange, GithubWebhook}
  alias Aiur.Events.GithubWebhook.Normalizer
  alias Aiur.GitHub.ReadCache

  @repo "owner/repo"

  describe "PR attribution" do
    test "PR references from body and commits publish a merge event for the referenced ticket" do
      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 902,
          "merged" => true,
          "body" => "Refs #5605",
          "head" => %{"ref" => "executor/quarantine", "sha" => "deadbeef"},
          "commit_messages" => ["Closes #5606"]
        }
      }

      assert {:publish, triples} = Normalizer.normalize("pull_request", delivery, repo: @repo)
      topics = Enum.map(triples, &elem(&1, 0))
      assert "ticket.5605.pr.merged" in topics
      assert "ticket.5606.pr.merged" in topics

      assert Enum.all?(triples, fn {_topic, _payload, opts} ->
               opts[:issue_number] in ["5605", "5606"]
             end)

      assert length(
               Enum.map(triples, fn {_topic, _payload, opts} -> opts[:dedup_key] end)
               |> Enum.uniq()
             ) == 2
    end

    test "commit-only references resolve a merged PR when its branch has no ticket id" do
      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 903,
          "merged" => true,
          "body" => "maintenance change",
          "head" => %{"ref" => "executor/quarantine", "sha" => "feedface"},
          "commit_messages" => ["Refs #5605"]
        }
      }

      assert {:publish, [{"ticket.5605.pr.merged", _event, opts}]} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)

      assert opts[:issue_number] == "5605"
    end

    test "a Refs-only merge is dropped when commit evidence cannot be fetched" do
      ReadCache.reset()

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 904,
          "merged" => true,
          "body" => "Refs #5606",
          "head" => %{"ref" => "executor/quarantine", "sha" => "badcafe"}
        }
      }

      assert {:drop, {:unresolved_ticket, "pull_request", 904}} =
               Normalizer.normalize("pull_request", delivery,
                 repo: @repo,
                 request_fun: fn _ -> {:error, :offline} end
               )
    end

    test "a ticket branch remains attributed when commit evidence cannot be fetched" do
      ReadCache.reset()

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 908,
          "merged" => true,
          "body" => "",
          "head" => %{"ref" => "aiur/5606-fix", "sha" => "badcafe"}
        }
      }

      assert {:publish, [{"ticket.5606.pr.merged", _event, _opts}]} =
               Normalizer.normalize("pull_request", delivery,
                 repo: @repo,
                 request_fun: fn _ -> {:error, :offline} end
               )
    end

    test "webhook commit lookup failure retains proven branch attribution" do
      ReadCache.reset()
      :ok = Exchange.subscribe("ticket.5606.pr.merged")

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "reviewer"},
        "pull_request" => %{
          "number" => 909,
          "merged" => true,
          "body" => "maintenance",
          "head" => %{"ref" => "aiur/5606-fix", "sha" => "failing-fetch-head"}
        }
      }

      assert %{status: :published, published: ["ticket.5606.pr.merged"]} =
               GithubWebhook.handle_delivery("pull_request", delivery,
                 repo: @repo,
                 token: "explicit-webhook-token",
                 request_fun: fn request ->
                   assert request.token == "explicit-webhook-token"
                   {:error, :offline}
                 end
               )

      assert_receive {:event, %{topic: "ticket.5606.pr.merged"}}, 500
    end

    test "a body closing link still publishes when commit evidence cannot be fetched" do
      ReadCache.reset()

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 907,
          "merged" => true,
          "body" => "Closes #5605",
          "head" => %{"ref" => "executor/patch", "sha" => "badcafe"}
        }
      }

      assert {:publish, triples} =
               Normalizer.normalize("pull_request", delivery,
                 repo: @repo,
                 request_fun: fn _ -> {:error, :offline} end
               )

      assert Enum.map(triples, &elem(&1, 0)) == ["ticket.5605.pr.merged"]
      assert Enum.map(triples, fn {_topic, _event, opts} -> opts[:issue_number] end) == ["5605"]
    end

    test "opened and ready PRs route by ticket branch and closing keyword, not Refs" do
      for action <- ["opened", "ready_for_review"] do
        delivery = %{
          "action" => action,
          "repository" => %{"full_name" => @repo},
          "pull_request" => %{
            "number" => 905,
            "merged" => false,
            "body" => "Refs #5605",
            "head" => %{"ref" => "aiur/5606-fix", "sha" => "deadbee"}
          }
        }

        assert {:publish, triples} = Normalizer.normalize("pull_request", delivery, repo: @repo)
        topic_action = if action == "opened", do: "opened", else: "ready_for_review"
        assert Enum.map(triples, &elem(&1, 0)) == ["ticket.5606.pr.#{topic_action}"]
      end
    end

    test "publisher delivers each merged reference target once" do
      :ok = Exchange.subscribe("ticket.5605.pr.merged")
      :ok = Exchange.subscribe("ticket.5606.pr.merged")

      delivery = %{
        "action" => "closed",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "reviewer"},
        "pull_request" => %{
          "number" => 906,
          "merged" => true,
          "body" => "Refs #5605",
          "head" => %{"ref" => "aiur/5605-quarantine", "sha" => "d15ea5e"},
          "commit_messages" => ["Closes #5606"]
        }
      }

      assert %{status: :published} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo)

      assert_receive {:event, %{topic: "ticket.5605.pr.merged"}}, 1000
      assert_receive {:event, %{topic: "ticket.5606.pr.merged"}}, 1000

      assert %{status: :published} =
               GithubWebhook.handle_delivery("pull_request", delivery, repo: @repo)

      refute_receive {:event, %{topic: _}}, 200
    end
  end
end
