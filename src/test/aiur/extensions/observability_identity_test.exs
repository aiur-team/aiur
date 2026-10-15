defmodule Aiur.Extensions.ObservabilityIdentityTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest, except: [build_conn: 0]
  @endpoint AiurWeb.Endpoint

  import Aiur.ExtensionsTestSupport
  alias Aiur.ExtensionsTestSupport.StaticOrchestrator

  setup do
    linear_client_module = Application.get_env(:aiur, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:aiur, :linear_client_module)
      else
        Application.put_env(:aiur, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:aiur, AiurWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "observability issue details include tracker-active idle rows" do
    snapshot = %{
      static_snapshot()
      | running: [],
        retrying: [],
        idle: [
          %{
            issue_id: "issue-idle",
            identifier: "MT-IDLE",
            state: "human-review",
            tag: "agent:human-review",
            title: "Awaiting review",
            url: "https://example.test/issues/idle",
            queue_depth: 2,
            waiting_reason: :waiting_for_review,
            open_decision_count: 1,
            ci_result: %{decision: :passed, pr_number: 1014, head_sha: "abc123"}
          }
        ]
    }

    orchestrator_name = Module.concat(__MODULE__, :IdleObservabilityApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"counts" => %{"idle" => 1}} =
             json_response(get(build_conn(), "/api/v1/state"), 200)

    assert %{
             "status" => "idle",
             "issue_id" => "issue-idle",
             "queue" => %{"depth" => 2},
             "idle" => %{
               "waiting_reason" => "waiting_for_review",
               "open_decision_count" => 1,
               "review" => "awaiting",
               "ci" => %{"decision" => "passed", "pr_number" => 1014, "head_sha" => "abc123"}
             }
           } = json_response(get(build_conn(), "/api/v1/MT-IDLE"), 200)
  end

  test "observability API preserves tracker identity in status and issue snapshots" do
    identity = %Aiur.TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDOHTTP",
      identifier: "MT-HTTP"
    }

    snapshot =
      update_in(static_snapshot(), [:running], fn [running] ->
        [Map.put(running, :tracker_identity, identity)]
      end)

    orchestrator_name = Module.concat(__MODULE__, :TrackerIdentityObservabilityApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{
             "running" => [
               %{
                 "tracker_identity" => %{
                   "version" => 1,
                   "status" => "joinable",
                   "kind" => "github",
                   "owner" => "owner",
                   "repository" => "repo",
                   "provider_id" => "I_kwDOHTTP",
                   "identifier" => "MT-HTTP"
                 }
               }
             ]
           } = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert %{
             "tracker_identity" => %{"provider_id" => "I_kwDOHTTP"},
             "running" => %{"tracker_identity" => %{"provider_id" => "I_kwDOHTTP"}}
           } = json_response(get(build_conn(), "/api/v1/MT-HTTP"), 200)
  end

  test "observability API rejects ambiguous identifier snapshots before exposing nested identity" do
    first_identity = %Aiur.TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo-one",
      provider_id: "I_kwDOFirst",
      identifier: "42"
    }

    second_identity = %{first_identity | repository: "repo-two", provider_id: "I_kwDOSecond"}

    snapshot =
      update_in(static_snapshot(), [:running], fn [running] ->
        first = Map.merge(running, %{identifier: "42", tracker_identity: first_identity})

        second =
          Map.merge(running, %{
            issue_id: "issue-http-second",
            identifier: "42",
            session_id: "thread-http-second",
            workspace_path: "/workspace/repo-two/42",
            tracker_identity: second_identity
          })

        [first, second]
      end)

    orchestrator_name = Module.concat(__MODULE__, :AmbiguousIdentityObservabilityApiOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/42"), 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }
  end
end
