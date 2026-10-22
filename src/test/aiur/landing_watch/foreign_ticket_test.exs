defmodule Aiur.LandingWatch.ForeignTicketTest do
  # #5803: the landing watcher neither enqueues nor routes rework for a PR whose
  # ticket another instance owns; a native ticket's PR still lands.
  use Aiur.TestSupport

  alias Aiur.LandingWatch

  @green %{"id" => 60, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 101}}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok
  end

  test "an approved green PR is enqueued for a native ticket and skipped for an ignored ticket id" do
    parent = self()
    assert :ok = LandingWatch.process(approved_observation("native-head"), landing_opts(parent, journal_path()))
    assert_received {:enqueued, "native-head"}
    assert_received {:ticket_state_read, "17"}

    ignore!("    tickets: [17]\n")
    assert :ok = LandingWatch.process(approved_observation("foreign-head"), landing_opts(parent, journal_path()))
    refute_received {:enqueued, _head}
    refute_received {:ticket_state_read, _}
  end

  test "a ticket carrying another instance's state-label prefix is skipped on the live label read" do
    parent = self()
    ignore!("    label_prefixes: [nuc]\n")

    request_fun = fn %{url: url} ->
      assert url =~ "/issues/17"
      {:ok, %{status: 200, body: %{"labels" => [%{"name" => "nuc:ci-wait"}]}, headers: []}}
    end

    opts =
      parent
      |> landing_opts(journal_path())
      |> Keyword.delete(:ticket_state_fun)
      |> Keyword.merge(repository: {"owner", "foreign-#{System.unique_integer([:positive])}"}, token: "t", request_fun: request_fun)

    assert :ok = LandingWatch.process(approved_observation("prefix-head"), opts)
    refute_received {:enqueued, _head}
  end

  test "rework routing does not transition an ignored ticket" do
    parent = self()
    ignore!("    tickets: [17]\n")

    opts = [
      ticket_state_fun: fn "17", _ -> {:ok, "human-review"} end,
      transition_fun: fn issue, state, _ -> send(parent, {:transition, issue, state}) && :ok end,
      journal_path: journal_path()
    ]

    LandingWatch.rework(approved_observation("rework-head"), [%{name: "CI failure"}], opts)
    refute_received {:transition, _, _}
  end

  defp ignore!(rules) do
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n" <> rules)
    :ok = Aiur.WorkflowStore.force_reload()
  end

  defp landing_opts(parent, path) do
    [
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [@green], commit_status: %{"state" => "success", "statuses" => []}}} end,
      revalidate_fun: fn 17, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      ticket_state_fun: fn "17", _ -> send(parent, {:ticket_state_read, "17"}) && {:ok, "ci-wait"} end,
      alert_emitter: fn _topic, _details -> :ok end,
      enqueue_fun: fn pr ->
        send(parent, {:enqueued, pr.head})
        {:ok, "entry-1"}
      end,
      journal_path: path
    ]
  end

  defp approved_observation(head) do
    %{
      number: 17,
      node_id: "PR_node",
      head: head,
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => head, "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => head}}]}}
    }
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-watch-foreign-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
