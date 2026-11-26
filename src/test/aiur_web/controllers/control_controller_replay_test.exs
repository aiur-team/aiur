defmodule Aiur.ControlReplayTestProbe do
  @moduledoc false

  # Reports every real execution to the registered test process, then blocks until released.
  def write_wait(parent_name) do
    send(Process.whereis(parent_name), {:replay_probe_ran, self()})

    receive do
      :finish -> IO.puts("done\n__AIUR_CONTROL_EXIT__:0")
    end
  end
end

defmodule AiurWeb.ControlControllerReplayTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.ControlCall.ReplayStore
  alias AiurWeb.Router

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_control_replay_test", signing_salt: "aiur-test-session")
  @parent :control_replay_probe
  @id_a "018f0000-0000-7000-8000-00000000000a"
  @id_b "018f0000-0000-7000-8000-00000000000b"
  @probe "Aiur.ControlReplayTestProbe.write_wait(:control_replay_probe)"

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    root = Path.join(System.tmp_dir!(), "control-replay-#{System.unique_integer([:positive])}")
    keys = [:client_tokens_path, :control_audit_file, :control_replay_state_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :client_tokens_path, Path.join(root, "tokens.json"))
    Application.put_env(:aiur, :control_audit_file, Path.join(root, "control-audit.ndjson"))
    Application.put_env(:aiur, :control_replay_state_dir, Path.join(root, "replay"))
    ReplayStore.reload()
    Process.register(self(), @parent)
    assert {:ok, write_token} = Aiur.ClientTokens.create("replay-write", "write")
    assert {:ok, other_token} = Aiur.ClientTokens.create("replay-other", "write")
    assert {:ok, read_token} = Aiur.ClientTokens.create("replay-read", "read")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:aiur, key)
        {key, value} -> Application.put_env(:aiur, key, value)
      end)

      ReplayStore.reload()
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{token: write_token, other: other_token, read: read_token, audit: Path.join(root, "control-audit.ndjson")}
  end

  test "same request id and body runs once and both responses are equal", %{token: token, audit: audit} do
    task = Task.async(fn -> post(token, @probe, @id_a) end)
    assert_receive {:replay_probe_ran, pid}, 2_000
    send(pid, :finish)
    first = Task.await(task)
    second = post(token, @probe, @id_a)

    refute_receive {:replay_probe_ran, _}, 200
    assert first.status == 200
    assert second.status == 200
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "x-aiur-replayed") == ["true"]
    assert get_resp_header(first, "x-aiur-replayed") == []

    [ran, replayed] = audit_records(audit)
    assert %{"request_id" => @id_a, "actor" => "token:replay-write", "origin_gateway" => "nook", "outcome" => "ok"} = ran
    assert %{"request_id" => @id_a, "outcome" => "replayed", "original_outcome" => "ok"} = replayed
  end

  test "same id with another expression is request_id_reused and does not run", %{token: token} do
    task = Task.async(fn -> post(token, @probe, @id_a) end)
    assert_receive {:replay_probe_ran, pid}, 2_000
    send(pid, :finish)
    Task.await(task)

    reused = post(token, "Aiur.AgentControlCLI.set_max_agents(3)", @id_a)
    assert reused.status == 422
    assert Jason.decode!(reused.resp_body)["error"]["code"] == "request_id_reused"
  end

  test "a second request while the first runs is 409 request_in_progress", %{token: token} do
    task = Task.async(fn -> post(token, @probe, @id_a) end)
    assert_receive {:replay_probe_ran, pid}, 2_000

    busy = post(token, @probe, @id_a)
    assert busy.status == 409
    assert Jason.decode!(busy.resp_body)["error"]["code"] == "request_in_progress"

    send(pid, :finish)
    assert Task.await(task).status == 200
    assert post(token, @probe, @id_a).status == 200
    refute_receive {:replay_probe_ran, _}, 200
  end

  test "the key includes the token", %{token: token, other: other} do
    for t <- [token, other] do
      task = Task.async(fn -> post(t, @probe, @id_a) end)
      assert_receive {:replay_probe_ran, pid}, 2_000
      send(pid, :finish)
      assert Task.await(task).status == 200
    end
  end

  test "contract version 1 ignores request_id and stores nothing", %{token: token} do
    for _ <- 1..2 do
      task = Task.async(fn -> post(token, @probe, @id_a, 1) end)
      assert_receive {:replay_probe_ran, pid}, 2_000
      send(pid, :finish)
      assert Task.await(task).status == 200
    end
  end

  test "a malformed or non-v7 request id is refused for writes", %{token: token} do
    for bad <- ["abc", "018f0000-0000-4000-8000-00000000000a"] do
      response = post(token, @probe, bad)
      assert response.status == 422
      assert Jason.decode!(response.resp_body)["error"]["code"] == "invalid_request_id"
    end

    refute_receive {:replay_probe_ran, _}, 100
  end

  test "a refused write is not stored", %{read: read, token: token} do
    assert post(read, @probe, @id_b).status == 403

    task = Task.async(fn -> post(token, @probe, @id_b) end)
    assert_receive {:replay_probe_ran, pid}, 2_000
    send(pid, :finish)
    assert Task.await(task).status == 200
  end

  test "a timed-out write replays its 504 without running again", %{token: token} do
    first = post(token, @probe, @id_a, 2, %{"timeout_ms" => 300})
    assert first.status == 504
    assert_receive {:replay_probe_ran, pid}, 1_000

    again = post(token, @probe, @id_a, 2, %{"timeout_ms" => 300})
    assert again.status == 504
    assert again.resp_body == first.resp_body
    refute_receive {:replay_probe_ran, _}, 200
    send(pid, :finish)
  end

  test "a call in flight when the store restarts becomes outcome_unknown and never reruns", %{token: token} do
    task = Task.async(fn -> post(token, @probe, @id_a) end)
    assert_receive {:replay_probe_ran, pid}, 2_000
    ReplayStore.reload()

    unknown = post(token, @probe, @id_a)
    assert unknown.status == 409
    assert Jason.decode!(unknown.resp_body)["error"]["code"] == "outcome_unknown"
    refute_receive {:replay_probe_ran, _}, 200

    send(pid, :finish)
    Task.await(task)
  end

  test "an unavailable store refuses the write before it runs", %{token: token} do
    Application.put_env(:aiur, :control_replay_state_dir, "/proc/definitely/not/writable")
    ReplayStore.reload()
    response = post(token, @probe, @id_a)

    assert response.status == 503
    assert Jason.decode!(response.resp_body)["error"]["code"] == "replay_store_unavailable"
    refute_receive {:replay_probe_ran, _}, 100
  end

  defp post(token, expression, request_id, version \\ 2, extra \\ %{}) do
    payload =
      Map.merge(
        %{"contract" => "aiur.control.call", "contract_version" => version, "expression" => expression, "request_id" => request_id, "origin_gateway" => "nook"},
        extra
      )

    conn(:post, "/api/v1/control", Jason.encode!(payload))
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
    |> AiurWeb.Session.call(@session_options)
    |> fetch_session()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))
    |> then(&Router.call(&1, Router.init([])))
  end

  defp audit_records(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
