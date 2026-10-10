defmodule Aiur.BuildOrder.SharedResourceStoreSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.GitHub.ResourceStore
  alias Aiur.TrackerIdentity

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @repository {"owner", "repo"}

  # The shared `setup`: a GitHub token, a GitHub workflow and an empty store.
  # Returns the request recorder.
  def prepare_shared_store do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    on_exit(fn ->
      Aiur.TestSupport.restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end
    end)

    Aiur.TestSupport.write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "sym"
    )

    ResourceStore.reset()

    start_recorder()
  end

  def stop_store! do
    on_exit(fn ->
      case Process.whereis(ResourceStore) do
        nil -> Supervisor.restart_child(Aiur.Supervisor, ResourceStore)
        _pid -> :ok
      end

      ResourceStore.reset()
    end)

    case Process.whereis(ResourceStore) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Supervisor.terminate_child(Aiur.Supervisor, ResourceStore)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> flunk("ResourceStore did not stop")
        end
    end
  end

  def issue_body(number) do
    %{
      "number" => number,
      "title" => "Ticket #{number}",
      "body" => "description",
      "html_url" => "https://github.com/owner/repo/issues/#{number}",
      "labels" => [%{"name" => "sym:todo"}],
      "assignee" => nil,
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  def ok_issue(number) do
    {:ok, %{status: 200, headers: [{"etag", "\"v1\""}], body: issue_body(number)}}
  end

  def ticket_identity(number, node_id) do
    {:ok, identity} =
      TrackerIdentity.from_github(
        %{"node_id" => node_id, "number" => number},
        @repository,
        @repository
      )

    identity
  end

  def start_recorder do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  def recording_fun(recorder, fun) do
    fn request ->
      Agent.update(recorder, &[request | &1])
      fun.(request)
    end
  end

  def requests(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()
  def count(recorder), do: recorder |> requests() |> length()

  # Reads of the issue resource itself, which is what these tests are about.
  #
  # The dispatch poll additionally reads `/issues/{n}/timeline` through
  # `Aiur.GitHub.DispatchAuthorization`. That is a genuinely different resource,
  # not a duplicate of this one, so counting it here would hide the thing being
  # measured. It is also still unconditional — named in the PR rather than
  # folded into a percentage, and out of scope for this change.
  def issue_requests(recorder) do
    recorder
    |> requests()
    |> Enum.filter(&String.match?(&1.url, ~r{/issues/\d+$}))
  end

  def issue_count(recorder), do: recorder |> issue_requests() |> length()
end
