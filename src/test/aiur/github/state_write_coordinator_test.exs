# Cohesion: these tests cover per-ticket GitHub state-write serialization and recovery.
defmodule Aiur.GitHub.StateWriteCoordinatorTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{IssueState, ResourceStore, StateWriteCoordinator}
  alias Aiur.Orchestrator.TicketTransition

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)
      ResourceStore.reset()
    end)

    :ok
  end

  test "concurrent state writers cannot remove each other's new state labels" do
    {:ok, labels} =
      Agent.start_link(fn ->
        %{labels: ["sym:todo"], initial_reads: 0, posts: 0, post_reads: 0}
      end)

    parent = self()
    request_fun = state_request_fun(labels, parent)

    results =
      [{"in-progress", :dispatcher}, {"rework", :comment_wake}]
      |> Enum.map(fn {state, writer} ->
        Task.async(fn ->
          TicketTransition.write_state("6110", state, writer: writer, request_fun: request_fun)
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert results == [:ok, :ok]
    assert Agent.get(labels, &state_labels/1) in [["sym:in-progress"], ["sym:rework"]]
    Agent.stop(labels)
  end

  test "a single different remaining state reports a replaced label and compares case-insensitively" do
    parent = self()

    alert = fn topic, metadata ->
      send(parent, {:replacement_alert, topic, metadata})
      :ok
    end

    context = %{
      issue_number: "6110",
      prefix: "sym",
      opts: [emit_state_label_alert_fun: alert]
    }

    assert {:error, {:state_label_replaced_after_swap, "SYM:REWORK"}} =
             StateWriteCoordinator.verify_state_labels(context, "sym:in-progress", ["SYM:REWORK"])

    assert_received {:replacement_alert, "ticket.6110.state_label_replaced_after_swap", metadata}
    assert metadata[:severity] == "critical"
    assert metadata[:message] =~ "instead of sym:in-progress"

    assert :ok =
             StateWriteCoordinator.verify_state_labels(context, "SYM:IN-PROGRESS", ["sym:in-progress"])

    refute_received {:replacement_alert, _, _}
  end

  test "an empty removal response restores the target and emits an alert" do
    parent = self()
    {:ok, labels} = Agent.start_link(fn -> ["sym:todo"] end)

    request_fun = fn
      %{method: :get} = request ->
        send(parent, {:recovery_request, request.method})
        {:ok, %{status: 200, body: %{"state" => "open", "labels" => label_objects_from_list(labels)}}}

      %{method: :post, body: %{"labels" => ["sym:in-progress"]}} = request ->
        send(parent, {:recovery_request, request.method})
        Agent.update(labels, &Enum.uniq(["sym:in-progress" | &1]))
        send(parent, {:state_label_add, "sym:in-progress"})
        {:ok, %{status: 200}}

      %{method: :delete} = request ->
        send(parent, {:recovery_request, request.method})
        Agent.update(labels, fn _ -> [] end)
        {:ok, %{status: 200, body: []}}

      request ->
        flunk("unexpected recovery request: #{inspect(request)}")
    end

    alert = fn topic, metadata ->
      send(parent, {:state_label_alert, topic, metadata})
      :ok
    end

    assert :ok =
             IssueState.update_issue_state("6110", "in-progress",
               request_fun: request_fun,
               emit_state_label_alert_fun: alert
             )

    assert_received {:state_label_add, "sym:in-progress"}
    assert_received {:state_label_add, "sym:in-progress"}
    assert_received {:state_label_alert, "ticket.6110.state_label_restored", metadata}
    assert_received {:recovery_request, :get}
    assert_received {:recovery_request, :get}
    assert_received {:recovery_request, :get}
    assert_received {:recovery_request, :get}
    assert_received {:recovery_request, :post}
    assert_received {:recovery_request, :delete}
    assert_received {:recovery_request, :post}
    refute_received {:recovery_request, _method}
    refute_received {:recovery_request, :post}
    refute_received {:recovery_request, :delete}
    assert metadata[:needs_attention]
    assert metadata[:severity] == "critical"
    assert metadata[:message] =~ "restoring sym:in-progress"
    Agent.stop(labels)
  end

  test "a removal without returned labels uses one verification read and restores zero state" do
    parent = self()

    for delete_status <- [204, 404] do
      {:ok, calls} = Agent.start_link(fn -> %{gets: 0, deletes: 0, methods: []} end)

      request_fun = fn
        %{method: :get} ->
          after_delete =
            Agent.get_and_update(calls, fn state ->
              next = %{state | gets: state.gets + 1, methods: [:get | state.methods]}
              {state.deletes > 0, next}
            end)

          labels = if after_delete, do: [], else: [%{"name" => "sym:todo"}]
          {:ok, %{status: 200, body: %{"state" => "open", "labels" => labels}}}

        %{method: :post} ->
          Agent.update(calls, &%{&1 | methods: [:post | &1.methods]})
          {:ok, %{status: 200}}

        %{method: :delete} ->
          Agent.update(calls, &%{&1 | deletes: &1.deletes + 1, methods: [:delete | &1.methods]})
          {:ok, %{status: delete_status}}
      end

      alert = fn topic, metadata ->
        send(parent, {:fallback_alert, delete_status, topic, metadata})
        :ok
      end

      assert :ok =
               IssueState.update_issue_state("6110", "in-progress",
                 request_fun: request_fun,
                 emit_state_label_alert_fun: alert
               )

      assert Agent.get(calls, &Enum.frequencies(&1.methods)) == %{get: 4, post: 2, delete: 1}
      assert_received {:fallback_alert, ^delete_status, "ticket.6110.state_label_restored", metadata}
      assert metadata[:severity] == "critical"
      Agent.stop(calls)
    end
  end

  defp state_request_fun(agent, parent) do
    fn request ->
      send(parent, {:state_request, request.method})

      case request.method do
        :get -> get_issue(agent)
        :post -> add_label(agent, request)
        :delete -> remove_label(agent, request)
      end
    end
  end

  defp get_issue(agent) do
    phase =
      Agent.get_and_update(agent, fn state ->
        next =
          if state.posts == 2,
            do: %{state | post_reads: state.post_reads + 1},
            else: %{state | initial_reads: state.initial_reads + 1}

        {next, next}
      end)

    if phase.posts == 0 and phase.initial_reads <= 2, do: await_pair(agent, :initial_reads)
    if phase.posts == 2 and phase.post_reads <= 2, do: await_pair(agent, :post_reads)
    {:ok, %{status: 200, body: issue_body(agent)}}
  end

  defp add_label(agent, request) do
    [label] = request.body["labels"]

    phase =
      Agent.get_and_update(agent, fn state ->
        labels = Enum.uniq([label | state.labels])
        next = %{state | labels: labels, posts: state.posts + 1}
        {next, next}
      end)

    if phase.posts == 2, do: await_pair(agent, :posts)
    {:ok, %{status: 200, body: %{"labels" => label_objects(agent)}}}
  end

  defp remove_label(agent, request) do
    label = request.url |> URI.decode() |> String.split("/labels/") |> List.last()

    Agent.update(
      agent,
      &%{
        &1
        | labels:
            Enum.reject(&1.labels, fn existing ->
              String.downcase(existing) == String.downcase(label)
            end)
      }
    )

    {:ok, %{status: 200, body: %{"labels" => label_objects(agent)}}}
  end

  defp await_pair(agent, key) do
    arrival =
      Agent.get_and_update(agent, fn state ->
        waiters = Map.get(state, :pair_waiters, %{})

        case Map.fetch(waiters, key) do
          :error ->
            {:wait, Map.put(state, :pair_waiters, Map.put(waiters, key, self()))}

          {:ok, first_pid} when is_pid(first_pid) ->
            {{:release, first_pid}, Map.put(state, :pair_waiters, Map.put(waiters, key, :released))}

          {:ok, :released} ->
            {:released, state}
        end
      end)

    case arrival do
      :wait ->
        receive do
          :pair_ready -> :ok
        after
          200 -> :ok
        end

      {:release, first_pid} ->
        send(first_pid, :pair_ready)
        :ok

      :released ->
        :ok
    end
  end

  defp issue_body(agent), do: %{"state" => "open", "labels" => label_objects(agent)}

  defp label_objects(agent),
    do: Agent.get(agent, &Enum.map(&1.labels, fn label -> %{"name" => label} end))

  defp label_objects_from_list(labels),
    do: Agent.get(labels, &Enum.map(&1, fn label -> %{"name" => label} end))

  defp state_labels(state),
    do:
      Enum.filter(
        state.labels,
        &(&1 in [
            "sym:todo",
            "sym:in-progress",
            "sym:rework",
            "sym:ci-wait",
            "sym:human-review",
            "sym:merging",
            "sym:done",
            "sym:error",
            "sym:cancelled",
            "sym:canceled"
          ])
      )
end
