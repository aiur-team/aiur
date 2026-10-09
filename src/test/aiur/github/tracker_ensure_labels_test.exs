Code.require_file("../../support/build_queue_fake_tracker.ex", __DIR__)

defmodule Aiur.GitHub.TrackerEnsureLabelsTest do
  use Aiur.TestSupport
  alias Aiur.BuildQueue.Writer
  alias Aiur.BuildQueueFakeTracker, as: Fake
  alias Aiur.{Tracker, Workflow}

  setup do
    previous = Map.new([:github_transport_test_options, :github_budget_enabled?, :github_quota_server], &{&1, Application.get_env(:aiur, &1)})
    token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")
    quota = start_supervised!({Aiur.GitHub.Quota, name: nil, emit_fun: fn _, _ -> :ok end})
    Application.put_env(:aiur, :github_transport_test_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:aiur, :github_quota_server, quota)
    Application.put_env(:aiur, :github_budget_enabled?, false)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", token)

      for {key, value} <- previous do
        if is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value)
      end
    end)

    :ok
  end

  test "facade ensures labels through GitHub and 422 already_exists counts as ensured" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:label_request, conn.method, conn.request_path, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"errors" => [%{"code" => "already_exists"}]})
    end)

    assert :ok = Tracker.ensure_labels(["agent:queued"])
    assert_received {:label_request, "POST", "/repos/owner/repo/labels", %{"name" => "agent:queued"}}
  end

  test "HTTP marker throttling pauses the writer before any marker or promotion" do
    document = %{queues: [], items: [], edges: [], intents: [], latches: []}
    Fake.reset(document)

    for status <- [403, 429] do
      quota = start_supervised!({Aiur.GitHub.Quota, name: nil, emit_fun: fn _, _ -> :ok end}, id: {:throttle, status})
      Application.put_env(:aiur, :github_quota_server, quota)
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:ensure_request, conn.request_path})
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => "You have exceeded a secondary rate limit."})
      end)

      context = %{
        document: document,
        tracker: Aiur.GitHub.Tracker,
        store: Fake,
        claim_probe: Fake,
        clock: &Fake.clock/0,
        sleep: &Fake.sleep/1,
        marker: "agent:queued",
        todo: "agent:todo",
        max_writes: 20,
        observation_max_age_ms: 120_000,
        observations: %{}
      }

      result = Writer.run(context, [{:mark, "1"}, {:promote, "2"}], Writer.new())
      assert result.status == :writes_paused
      assert_received {:ensure_request, "/repos/owner/repo/labels"}
      refute_received {:ensure_request, _}
      assert result.document.intents == []
      assert result.writer.failures == %{}
    end
  end

  test "ensure surfaces label errors and the non-GitHub adapter contracts" do
    Req.Test.stub(__MODULE__, fn conn -> conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"errors" => [%{"code" => "invalid"}]}) end)
    assert {:error, {:github_api_status, 422, "agent:queued"}} = Tracker.ensure_labels(["agent:queued"])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert :ok = Tracker.ensure_labels(["agent:queued"])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert {:error, :unsupported} = Tracker.ensure_labels(["agent:queued"])
    assert {:ensure_labels, 1} in Tracker.behaviour_info(:optional_callbacks)
  end
end
