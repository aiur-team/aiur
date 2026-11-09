defmodule Aiur.Ownership.PeerCacheTest do
  # A real `aiur gateway status` read fills the cache that `aiur ticket assign --to <peer>` judges.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.Gateway.Status
  alias Aiur.Handoff.CLI, as: HandoffCLI
  alias Aiur.Ownership.{CLI, PeerState, Record}

  @repo "O/R"
  @nook "bbbbbbbbbbbbbbbbbbbbbbbbbb"
  @pc "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    dir = Path.join(System.tmp_dir!(), "peer-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    env = [:gateway_registry_path, :remote_state_dir, :ownership_state_dir]
    previous = Map.new(env, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :gateway_registry_path, Path.join(dir, "remote-instances.yaml"))
    Application.put_env(:aiur, :remote_state_dir, Path.join(dir, "remote-state"))
    Application.put_env(:aiur, :ownership_state_dir, Path.join(dir, "ownership"))
    File.write!(Path.join(dir, "remote-instances.yaml"), "version: 1\ninstances:\n  pc:\n    url: http://pc.test:4000\n    gateway_id: \"#{@pc}\"\n")

    on_exit(fn ->
      for {k, v} <- previous, do: if(is_nil(v), do: Application.delete_env(:aiur, k), else: Application.put_env(:aiur, k, v))
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    :ok
  end

  # The peer's own `agents --json` answer, produced by the real handler with its gateway facts injected.
  defp read_pc(facts, now) do
    output = capture_io(fn -> HandoffCLI.agents(snapshot: %{running: []}, gateway: facts) end)
    hello = fn _url -> {:ok, %{"gateway_id" => @pc, "gateway_label" => "PC"}} end
    capture_io(fn -> Status.run(data: Jason.encode!([%{"name" => "pc", "status" => 0, "output" => output}]), now: now, http_get: hello, json: true) end)
  end

  defp assign(now) do
    test = self()

    {:ok, rec} =
      Record.new(%{
        repo: @repo,
        ticket: "12",
        state: "owned",
        gateway_id: @nook,
        gateway_label: "Nook",
        daemon_key: "nook",
        epoch: 4,
        previous_epoch: 3,
        actor: %{kind: "daemon", id: "nook"},
        reason: "dispatch",
        at: "2026-11-06T11:59:00Z"
      })

    observed = %{oid: "oid1", repository_id: "R1", record: rec}

    opts = [
      ticket: "12",
      repo: @repo,
      now: now,
      to: "pc",
      reason: "x",
      error_fun: &send(test, {:error, &1}),
      identity_fun: fn -> %{gateway_id: @nook, gateway_label: "Nook", daemon_key: "nook"} end,
      liveness_fun: fn _ -> %{status: :offline, source: nil, age_ms: nil} end,
      read_fun: fn @repo, "12" -> {:ok, observed} end,
      transfer_fun: fn @repo, "12", ^observed, owner ->
        send(test, {:transfer, owner})
        {:won, %{rec | epoch: 5, previous_epoch: 4, gateway_id: owner.gateway_id, gateway_label: owner.gateway_label, daemon_key: owner.daemon_key, reason: "transfer"}}
      end,
      delegation_fun: &send(test, {:delegation, &1}),
      open_pr_fun: fn "12" -> {:skip, :no_open_pr} end
    ]

    capture_io(fn -> send(test, {:code, CLI.assign(opts)}) end)
    assert_received {:code, code}
    code
  end

  test "before any read the peer is unknown and nothing is written" do
    assert assign(DateTime.utc_now()) == 64
    assert_received {:error, "aiur: unknown gateway \"pc\"" <> _}
    refute_received {:transfer, _}
  end

  test "a fresh read lacking the repo makes assign refuse" do
    now = DateTime.utc_now()
    read_pc(%{daemon_key: "pc-key", projects: ["a/b"]}, now)

    assert %{gateway_id: @pc, label: "PC", daemon_key: "pc-key", projects: ["a/b"]} = PeerState.peer("pc")
    assert assign(now) == 64
    assert_received {:error, "aiur: pc does not run O/R"}
    refute_received {:transfer, _}
  end

  test "a read listing the repo (any case) lets assign write the transfer with the peer's daemon key" do
    now = DateTime.utc_now()
    read_pc(%{daemon_key: "pc-key", projects: ["o/r"]}, now)

    assert assign(now) == 0
    assert_received {:transfer, %{gateway_id: @pc, daemon_key: "pc-key"}}
  end

  test "a stale negative read warns and writes" do
    now = DateTime.utc_now()
    read_pc(%{daemon_key: "pc-key", projects: ["a/b"]}, DateTime.add(now, -3600))

    assert assign(now) == 0
    assert_received {:error, "aiur: warning: pc did not answer; its last list (60 min old) lacked O/R; transfer written"}
    assert_received {:transfer, %{daemon_key: "pc-key"}}
  end

  test "an older peer that omits its facts is cached with no key, so assign refuses rather than guessing" do
    now = DateTime.utc_now()
    read_pc(%{}, now)

    assert %{daemon_key: nil, projects: nil} = PeerState.peer(@pc)
    assert assign(now) == 64
    assert_received {:error, "aiur: PC's daemon key is unknown; nothing written"}
  end
end
