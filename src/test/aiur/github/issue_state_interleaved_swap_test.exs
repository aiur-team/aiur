defmodule Aiur.GitHub.IssueStateInterleavedSwapTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.{IssueState, ResourceStore}

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)

      case previous_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "nuc"
    )

    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    :ok
  end

  test "concurrent state swaps serialize with a non-default prefix" do
    key = ResourceStore.key_for_repo(:issue, "owner/repo", "42")
    stale_issue = %{"state" => "open", "labels" => [%{"name" => "nuc:todo"}]}
    :ok = ResourceStore.put_resource(key, stale_issue)

    labels = :ets.new(:interleaved_issue_state_labels, [:set, :public])
    :ets.insert(labels, {:values, ["nuc:todo"]})
    parent = self()
    ref = make_ref()
    request_fun = request_fun(parent, labels, ref)

    first_swap =
      Task.async(fn ->
        Process.put(:issue_state_target, :rework)
        IssueState.update_issue_state("42", "rework", request_fun: request_fun)
      end)

    assert_receive {:rework_add_waiting}, 1_000

    second_swap =
      Task.async(fn ->
        Process.put(:issue_state_target, :in_progress)
        IssueState.update_issue_state("42", "in-progress", request_fun: request_fun)
      end)

    refute_receive {:in_progress_add_waiting}, 50
    send(first_swap.pid, {:release_rework_add, ref})
    assert :ok = Task.await(first_swap, 1_000)
    assert_receive {:in_progress_add_waiting}, 1_000
    assert :ok = Task.await(second_swap, 1_000)

    assert :ets.lookup_element(labels, :values, 2) == ["nuc:in-progress"]
  end

  defp request_fun(parent, labels, ref) do
    fn request ->
      target = Process.get(:issue_state_target)

      case request.method do
        :get ->
          removal_response(labels, request)

        :post ->
          add_state_request(parent, labels, ref, target, request)

        :delete ->
          label = request.url |> String.split("/") |> List.last() |> URI.decode()
          remove_state_label(labels, label)
          {:ok, %{status: 204}}
      end
    end
  end

  defp add_state_request(parent, labels, ref, :rework, request) do
    send(parent, {:rework_add_waiting})
    await_rework_add(labels, ref, request.body["labels"])
  end

  defp add_state_request(parent, labels, _ref, :in_progress, request) do
    send(parent, {:in_progress_add_waiting})
    add_state_label(labels, request.body["labels"])
    {:ok, %{status: 200}}
  end

  defp await_rework_add(labels, ref, new_labels) do
    receive do
      {:release_rework_add, ^ref} ->
        add_state_label(labels, new_labels)
        {:ok, %{status: 200}}
    after
      2_000 -> {:error, :timed_out_waiting_to_add_rework}
    end
  end

  defp removal_response(labels, _request) do
    issue = %{
      "state" => "open",
      "labels" => Enum.map(:ets.lookup_element(labels, :values, 2), &%{"name" => &1})
    }

    {:ok, %{status: 200, body: issue}}
  end

  defp add_state_label(labels, [label]) do
    current = :ets.lookup_element(labels, :values, 2)
    :ets.insert(labels, {:values, Enum.uniq([label | current])})
  end

  defp remove_state_label(labels, label) do
    current = :ets.lookup_element(labels, :values, 2)
    :ets.insert(labels, {:values, List.delete(current, label)})
  end
end
