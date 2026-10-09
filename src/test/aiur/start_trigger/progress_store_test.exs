defmodule Aiur.StartTrigger.ProgressStoreTest do
  use Aiur.TestSupport
  alias Aiur.{CIApprovalStore, StartTrigger}
  alias Aiur.Events.GithubWebhook.Deposit
  alias Aiur.GitHub.{BlockerProgress, ResourceStore}
  alias Aiur.StartTrigger.ProgressStore

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    :ok = Supervisor.terminate_child(Aiur.Supervisor, ProgressStore)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, ProgressStore) end)
    :ok
  end

  defp start(opts \\ []) do
    start_supervised!({ProgressStore, opts})
  end

  defp flush do
    :sys.get_state(ProgressStore)
    :sys.get_state(ProgressStore)
  end

  test "same PR only advances, replacement resets and closure clears" do
    start()
    ProgressStore.record("12", %{pr_number: 99, stage: :pr_ci_green})
    ProgressStore.record("12", %{pr_number: 99, stage: :pr_opened})
    flush()
    assert %{pr_number: 99, stage: :pr_ci_green} = ProgressStore.lookup("12")
    ProgressStore.record("12", %{pr_number: 120, stage: :pr_opened})
    flush()
    assert %{pr_number: 120, stage: :pr_opened} = ProgressStore.lookup("12")
    ProgressStore.record("12", %{pr_number: 120, closed_unmerged?: true})
    flush()
    assert %{stage: nil, closed_unmerged?: true} = ProgressStore.lookup("12")
    ProgressStore.record("12", %{pr_number: 120, stage: :pr_ci_green, source: :ci})
    flush()
    assert %{stage: nil, closed_unmerged?: true} = ProgressStore.lookup("12")
  end

  test "missing owner returns no row and writes do not fail writers" do
    assert ProgressStore.lookup("12") == nil
    assert :ok = ProgressStore.record("12", %{pr_number: 99, stage: :pr_opened})
  end

  test "draft delivers nothing, ready opens, merged satisfies final and closed clears" do
    start()
    pr = %{"number" => 99, "state" => "open", "draft" => true, "merged" => false, "head" => %{"ref" => "aiur/12-progress", "sha" => "head", "repo" => %{"full_name" => "owner/repo"}}}
    deposit(pr)
    assert ProgressStore.lookup("12") == nil
    deposit(%{pr | "draft" => false})
    assert %{stage: :pr_opened} = ProgressStore.lookup("12")
    deposit(%{pr | "state" => "closed", "merged" => true})
    assert %{stage: :pr_merged} = row = ProgressStore.lookup("12")
    evidence = %StartTrigger.Evidence{issue_open?: true, stage_reached: row.stage, observed_at_ms: 100}
    assert {:satisfied, :final} = StartTrigger.edge_verdict(:pr_merged, evidence, now_ms: 100, max_age_ms: 60_000)
    deposit(%{pr | "state" => "closed"})
    assert %{stage: nil, closed_unmerged?: true} = ProgressStore.lookup("12")
  end

  test "delayed deliveries cannot reverse closure or merge, and foreign repositories contribute nothing" do
    start(repo: fn -> "owner/repo" end)
    ResourceStore.reset()

    pr = %{
      "number" => 101,
      "state" => "closed",
      "draft" => false,
      "merged" => false,
      "updated_at" => "2026-10-09T10:02:00Z",
      "head" => %{"ref" => "aiur/31-progress", "repo" => %{"full_name" => "owner/repo"}}
    }

    deposit(pr)
    deposit(%{pr | "state" => "open", "updated_at" => "2026-10-09T10:01:00Z"})
    assert %{stage: nil, closed_unmerged?: true} = ProgressStore.lookup("31")
    deposit(%{pr | "merged" => true, "updated_at" => "2026-10-09T10:03:00Z"})
    deposit(pr)
    assert %{stage: :pr_merged, closed_unmerged?: false} = ProgressStore.lookup("31")
    deposit(%{pr | "number" => 102, "head" => %{"ref" => "aiur/32-progress", "repo" => %{"full_name" => "fork/repo"}}})
    assert ProgressStore.lookup("32") == nil
    foreign = %{pr | "number" => 103, "head" => %{"ref" => "aiur/33-progress", "repo" => %{"full_name" => "other/repo"}}}
    Deposit.deposit("pull_request", %{"pull_request" => foreign}, "other/repo")
    flush()
    assert ProgressStore.lookup("33") == nil
  end

  test "restart seeds durable CI greens and binds only the saved head" do
    path = Path.join(System.tmp_dir!(), "progress-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :ci_approval_store_path)
    Application.put_env(:aiur, :ci_approval_store_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :ci_approval_store_path, previous), else: Application.delete_env(:aiur, :ci_approval_store_path)
      File.rm!(path)
    end)

    CIApprovalStore.save(%{}, %{}, %{}, %{"12" => "passed-head", "13" => "old-head"})

    for {id, number, sha} <- [{"12", 99, "passed-head"}, {"13", 100, "new-head"}] do
      pr = %{"number" => number, "state" => "open", "draft" => false, "merged" => false, "head" => %{"ref" => "aiur/#{id}-progress", "sha" => sha, "repo" => %{"full_name" => "owner/repo"}}}
      Deposit.deposit("pull_request", %{"pull_request" => pr}, "owner/repo")
    end

    start(seed: &CIApprovalStore.load/0, identity: &BlockerProgress.identity/1)
    assert %{stage: :pr_ci_green, pr_number: 99} = ProgressStore.lookup("12")
    assert %{stage: :pr_opened, pr_number: 100} = ProgressStore.lookup("13")
    ProgressStore.record("12", %{pr_number: 99, stage: :pr_opened, head_sha: "passed-head"})
    ProgressStore.record("13", %{pr_number: 100, stage: :pr_opened, head_sha: "new-head"})
    flush()
    assert %{pr_number: 99, stage: :pr_ci_green} = ProgressStore.lookup("12")
    assert %{pr_number: 100, stage: :pr_opened} = ProgressStore.lookup("13")
  end

  test "only watched approvals are read, renewals are bounded, expiry stops reads" do
    owner = self()
    {:ok, clock} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    now = fn -> Agent.get(clock, & &1) end

    start(
      clock: now,
      reader: fn id, _row ->
        send(owner, {:read, id})
        {:ok, %{pr_number: 99, stage: :pr_approved, source: :review}}
      end
    )

    ProgressStore.record("unwatched", %{pr_number: 88, stage: :pr_opened})
    ProgressStore.watch(["12"], :pr_approved, observation_max_age_ms: 60_000)
    flush()
    assert_received {:read, "12"}
    refute_received {:read, "unwatched"}
    assert %{stage: :pr_approved} = ProgressStore.lookup("12")
    ProgressStore.watch(["12"], :pr_approved, observation_max_age_ms: 60_000)
    flush()
    refute_received {:read, "12"}
    Agent.update(clock, &(&1 + 60_000))
    send(Process.whereis(ProgressStore), :refresh)
    assert flush().watches == %{}
    refute_received {:read, "12"}
  end

  test "dismissal and reader error leave reached approval unchanged; error logs once" do
    owner = self()
    {:ok, mode} = Agent.start_link(fn -> :approved end)
    {:ok, clock} = Agent.start_link(fn -> System.system_time(:millisecond) end)

    start(
      clock: fn -> Agent.get(clock, & &1) end,
      reader: fn _id, _row ->
        send(owner, :read)

        case Agent.get(mode, & &1) do
          :approved -> {:ok, %{pr_number: 99, stage: :pr_approved}}
          :dismissed -> {:ok, %{pr_number: 99, stage: :pr_opened}}
          :error -> {:error, :timeout}
        end
      end
    )

    ProgressStore.watch(["12"], :pr_approved, observation_max_age_ms: 60_000)
    flush()
    assert_received :read

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for outcome <- [:dismissed, :error, :error] do
          previous = ProgressStore.lookup("12")
          Agent.update(mode, fn _ -> outcome end)
          Agent.update(clock, &(&1 + 30_000))
          ProgressStore.watch(["12"], :pr_approved, observation_max_age_ms: 60_000)
          flush()
          assert_received :read
          assert %{stage: :pr_approved} = ProgressStore.lookup("12")
          if outcome == :error, do: assert(ProgressStore.lookup("12") == previous)
        end
      end)

    assert length(Regex.scan(~r/Blocker approval read failed/, log)) == 1
  end

  defp deposit(pr) do
    Deposit.deposit("pull_request", %{"pull_request" => pr}, "owner/repo")
    flush()
  end
end
