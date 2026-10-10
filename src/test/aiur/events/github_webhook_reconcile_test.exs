defmodule Aiur.Events.GithubWebhookReconcileTest do
  @moduledoc """
  State-owned deliveries normalize to a reconcile hint. Split out of
  `github_webhook_test.exs`.
  """

  use Aiur.TestSupport.WebhookTailCase

  alias Aiur.Events.GithubWebhook
  alias Aiur.Events.GithubWebhook.Normalizer

  @repo "owner/repo"

  describe "state-owned events reconcile rather than publishing a parallel shape" do
    test "an issues labeled delivery asks the orchestrator to reconcile now" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      parent = self()

      delivery = %{
        "action" => "labeled",
        "repository" => %{"full_name" => @repo},
        "issue" => %{"number" => String.to_integer(ticket), "updated_at" => "2026-06-24T12:00:00Z"},
        "label" => %{"name" => "agent:rework"}
      }

      assert %{status: :reconciled, hint: %{kind: :issue_state, ticket: ^ticket, action: "labeled"}} =
               GithubWebhook.handle_delivery("issues", delivery,
                 repo: @repo,
                 reconcile_fun: fn hint -> send(parent, {:reconcile, hint}) end
               )

      assert_receive {:reconcile, %{kind: :issue_state, ticket: ^ticket}}, 1000
    end

    test "unlabeled, closed, reopened and opened reconcile the same way, so out-of-order deliveries converge" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      for action <- ["unlabeled", "closed", "reopened", "opened"] do
        delivery = %{
          "action" => action,
          "repository" => %{"full_name" => @repo},
          "issue" => %{"number" => String.to_integer(ticket), "updated_at" => "2026-06-24T12:00:00Z"}
        }

        assert {:reconcile, %{kind: :issue_state, ticket: ^ticket, action: ^action}} =
                 Normalizer.normalize("issues", delivery, repo: @repo)
      end
    end

    test "a completed check suite reconciles the CI lifecycle for its ticket" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery = %{
        "action" => "completed",
        "repository" => %{"full_name" => @repo},
        "check_suite" => %{
          "head_sha" => "deadbeef",
          "conclusion" => "failure",
          "pull_requests" => [%{"number" => 901, "head" => %{"ref" => "aiur/#{ticket}-slug"}}]
        }
      }

      assert {:reconcile, %{kind: :ci, tickets: [^ticket], head_sha: "deadbeef", conclusion: "failure"}} =
               Normalizer.normalize("check_suite", delivery, repo: @repo)
    end

    test "a completed check run reconciles the same way" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery = %{
        "action" => "completed",
        "repository" => %{"full_name" => @repo},
        "check_run" => %{
          "head_sha" => "deadbeef",
          "conclusion" => "success",
          "pull_requests" => [%{"number" => 901, "head" => %{"ref" => "aiur/#{ticket}-slug"}}]
        }
      }

      assert {:reconcile, %{kind: :ci, tickets: [^ticket], source: "check_run"}} =
               Normalizer.normalize("check_run", delivery, repo: @repo)
    end

    test "a resolved pull request review thread reconciles without publishing a comment" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery = %{
        "action" => "resolved",
        "repository" => %{"full_name" => @repo},
        "pull_request" => %{
          "number" => 901,
          "head" => %{"ref" => "aiur/#{ticket}-slug", "repo" => %{"full_name" => @repo}}
        },
        "thread" => %{"node_id" => "PRRT_resolved", "is_resolved" => true, "updated_at" => "2026-08-21T10:00:00Z"}
      }

      assert {:reconcile,
              %{
                kind: :review_thread,
                ticket: ^ticket,
                action: "resolved",
                thread_id: "PRRT_resolved",
                generation: "2026-08-21T10:00:00Z"
              }} =
               Normalizer.normalize("pull_request_review_thread", delivery, repo: @repo)
    end

    test "an in-progress check is dropped" do
      delivery = %{
        "action" => "created",
        "repository" => %{"full_name" => @repo},
        "check_run" => %{"head_sha" => "deadbeef"}
      }

      assert {:drop, {:uninteresting_action, "check_run", "created"}} =
               Normalizer.normalize("check_run", delivery, repo: @repo)
    end

    test "a synchronize push invalidates review state through the CI reconciler" do
      ticket = Integer.to_string(System.unique_integer([:positive]))

      delivery = %{
        "action" => "synchronize",
        "repository" => %{"full_name" => @repo},
        "sender" => %{"login" => "its-everdred"},
        "pull_request" => %{"number" => 901, "head" => %{"ref" => "aiur/#{ticket}-slug", "sha" => "newsha"}}
      }

      assert {:reconcile, %{kind: :ci, ticket: ^ticket, head_sha: "newsha", action: "synchronize"}} =
               Normalizer.normalize("pull_request", delivery, repo: @repo)
    end

    test "review-thread resolution changes request targeted comment reconciliation" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      parent = self()

      for action <- ["resolved", "unresolved"] do
        delivery = review_thread_delivery(ticket, action)

        assert %{
                 status: :reconciled,
                 hint: %{
                   kind: :review_thread,
                   ticket: ^ticket,
                   action: ^action,
                   thread_id: "PRRT_kwDOabc",
                   generation: "2026-08-21T12:00:00Z"
                 }
               } =
                 GithubWebhook.handle_delivery("pull_request_review_thread", delivery,
                   repo: @repo,
                   reconcile_fun: fn hint -> send(parent, {:reconcile, hint}) end
                 )

        assert_receive {:reconcile, %{kind: :review_thread, ticket: ^ticket, action: ^action}}, 1000
      end
    end

    test "review-thread reconciliation uses the admitted delivery id when the timestamp is null" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      delivery = Map.put(review_thread_delivery(ticket, "unresolved"), "updated_at", nil)

      assert %{hint: %{generation: "delivery-123"}} =
               GithubWebhook.handle_delivery("pull_request_review_thread", delivery,
                 repo: @repo,
                 delivery_id: "delivery-123",
                 reconcile_fun: fn _hint -> :ok end
               )
    end

    test "review-thread deliveries reject malformed, irrelevant, and unmapped payloads" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      delivery = review_thread_delivery(ticket, "unresolved")

      assert {:drop, {:uninteresting_action, "pull_request_review_thread", "created"}} =
               delivery
               |> Map.put("action", "created")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      assert {:error, {:malformed_payload, "pull_request_review_thread"}} =
               delivery
               |> Map.delete("thread")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      # A payload whose pull request names no head repository at all is
      # malformed, not an untracked fork: there is no repo to compare, so the
      # drop reason would be a misleading `{:untracked_head_repository, nil}`
      # that reads like a tracking decision when the payload is simply missing
      # the field.
      assert {:error, {:malformed_payload, "pull_request_review_thread"}} =
               delivery
               |> put_in(["pull_request", "head"], %{"ref" => "aiur/#{ticket}-slug"})
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      assert {:drop, {:unresolved_ticket, "pull_request_review_thread", "unresolved"}} =
               delivery
               |> put_in(["pull_request", "head", "ref"], "feature/no-ticket")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))

      assert {:drop, {:untracked_head_repository, "contributor/fork"}} =
               delivery
               |> put_in(["pull_request", "head", "repo", "full_name"], "contributor/fork")
               |> then(&Normalizer.normalize("pull_request_review_thread", &1, repo: @repo))
    end

    test "review-thread hints bypass the generic reconcile debounce" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      GithubWebhook.reset_reconcile_window()
      on_exit(&GithubWebhook.reset_reconcile_window/0)

      for action <- ["resolved", "unresolved"] do
        assert %{status: :reconciled} =
                 GithubWebhook.handle_delivery("pull_request_review_thread", review_thread_delivery(ticket, action),
                   repo: @repo,
                   orchestrator: self()
                 )
      end

      assert_receive {:github_webhook_reconcile, %{action: "resolved"}}, 500
      assert_receive {:github_webhook_reconcile, %{action: "unresolved"}}, 500
      refute_receive :request_refresh, 100
    end

    test "a check suite for an untracked branch is dropped" do
      delivery = %{
        "action" => "completed",
        "repository" => %{"full_name" => @repo},
        "check_suite" => %{"head_sha" => "deadbeef", "pull_requests" => [%{"head" => %{"ref" => "develop"}}]}
      }

      assert {:drop, {:unresolved_ticket, "check_suite", "completed"}} =
               Normalizer.normalize("check_suite", delivery, repo: @repo)
    end
  end
end
