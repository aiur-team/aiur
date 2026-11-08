Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Gateway.EnrolCliTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.ClientTokens
  alias Aiur.Gateway.{Cli, Identity, Invites, Registry}
  alias Aiur.Identity.Machine

  @peer "aaaaaaaaaaaaaaaaaaaaaaaaaa"

  setup %{dir: dir} do
    keys = [{Machine, :boot_result}, {Machine, :boot_context}]
    previous = Map.new(keys, &{&1, :persistent_term.get(&1, :absent)})
    env = [:gateway_registry_path, :control_audit_file, :client_tokens_path, :gateway_invites_path]
    previous_env = Map.new(env, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :gateway_registry_path, Path.join(dir, "remote-instances.yaml"))
    Application.put_env(:aiur, :control_audit_file, Path.join(dir, "control-audit.ndjson"))
    Application.put_env(:aiur, :client_tokens_path, Path.join(dir, "tokens.json"))
    Application.put_env(:aiur, :gateway_invites_path, Path.join(dir, "invites.json"))
    {:ok, _} = Machine.ensure(dir: Path.join(dir, "machine"))

    on_exit(fn ->
      for {k, v} <- previous, do: if(v == :absent, do: :persistent_term.erase(k), else: :persistent_term.put(k, v))
      for {k, v} <- previous_env, do: if(is_nil(v), do: Application.delete_env(:aiur, k), else: Application.put_env(:aiur, k, v))
    end)

    :ok
  end

  defp run(fun, opts), do: ExUnit.CaptureIO.capture_io(fn -> ExUnit.CaptureIO.capture_io(:stderr, fn -> apply(Cli, fun, [opts]) end) |> IO.write() end)
  defp exit_code(out), do: out |> then(&Regex.run(~r/__AIUR_CONTROL_EXIT__:(\d+)/, &1)) |> List.last() |> String.to_integer()
  defp credentials, do: elem(Registry.get(), 1).peers["nook"].credentials

  defp enrol_peer do
    File.write!(Registry.path(), "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n    allows:\n      categories: [read]\n      credentials: [peer-nook-1]\n")
    {:ok, token} = ClientTokens.create("peer-nook-1", "read", peer: @peer, categories: ["read"])
    token
  end

  test "invite prints one decodable code and stores only the hash of its secret" do
    out = run(:invite, categories: ["read", "message"], url: "https://b.example.ts.net/", ttl: 120)
    assert exit_code(out) == 0
    [code] = Regex.run(~r/aiur-invite:\S+/, out)
    payload = code |> String.replace_prefix("aiur-invite:", "") |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert %{"v" => 1, "url" => "https://b.example.ts.net", "fp" => nil, "id" => id, "secret" => "aiur_inv_" <> _, "gateway_id" => gateway_id} = payload
    assert gateway_id == Identity.current().gateway_id
    assert (payload["exp"] - System.os_time(:second)) in 118..120
    assert out =~ "no TLS pin"
    assert {:ok, [%{"id" => ^id, "grants" => ["read", "message"]}]} = Invites.list()
    refute File.read!(Application.get_env(:aiur, :gateway_invites_path)) =~ payload["secret"]
  end

  test "invite carries a supplied pin and refuses trust, a bad pin, a bad ttl and a missing url" do
    pin = String.duplicate("ab", 32)
    out = run(:invite, url: "https://b.example.ts.net", tls_pin: pin)
    [code] = Regex.run(~r/aiur-invite:\S+/, out)
    assert %{"fp" => ^pin} = code |> String.replace_prefix("aiur-invite:", "") |> Base.url_decode64!(padding: false) |> Jason.decode!()
    refute out =~ "no TLS pin"

    before = Invites.list()
    assert exit_code(run(:invite, url: "https://b.example.ts.net", categories: ["trust"])) == 64
    assert exit_code(run(:invite, url: "https://b.example.ts.net", tls_pin: "xyz")) == 64
    assert exit_code(run(:invite, url: "https://b.example.ts.net", ttl: 0)) == 64
    assert exit_code(run(:invite, url: "not a url")) == 64
    assert Invites.list() == before
  end

  test "remove deletes the entry and every token bound to the peer, and nobody else's" do
    enrol_peer()
    {:ok, _} = ClientTokens.create("bystander", "read")

    assert exit_code(run(:remove, peer: "nook")) == 0
    assert elem(Registry.get(), 1).peers == %{}
    assert Enum.map(elem(ClientTokens.list(), 1), & &1["name"]) == ["bystander"]
    assert exit_code(run(:remove, peer: "nook")) == 66
  end

  test "rotate mints a new token, keeps the old one for 10 minutes, then drops it" do
    old = enrol_peer()
    out = run(:rotate, peer: "nook")
    assert exit_code(out) == 0
    [new] = Regex.run(~r/^aiur_\S+$/m, out)

    now = DateTime.utc_now()
    assert {:ok, %{name: "peer-nook-2", peer: @peer}} = ClientTokens.authenticate_full(new, now)
    assert {:ok, %{name: "peer-nook-1"}} = ClientTokens.authenticate_full(old, DateTime.add(now, 599))
    assert :error = ClientTokens.authenticate_full(old, DateTime.add(now, 601))
    assert credentials() == ["peer-nook-1", "peer-nook-2"]

    assert :ok = Cli.finish_rotation(@peer, "peer-nook-1")
    assert credentials() == ["peer-nook-2"]
    assert Enum.map(elem(ClientTokens.list(), 1), & &1["name"]) == ["peer-nook-2"]
  end

  test "rotate of a peer with no token exits 66 and writes nothing" do
    File.write!(Registry.path(), "version: 1\ninstances:\n  nook:\n    gateway_id: \"#{@peer}\"\n")
    assert exit_code(run(:rotate, peer: "nook")) == 66
    assert elem(ClientTokens.list(), 1) == []
  end

  test "a token store written before expires_at existed still authenticates" do
    File.write!(Application.get_env(:aiur, :client_tokens_path), Jason.encode!([%{"name" => "old", "scope" => "read", "hash" => String.duplicate("0", 64), "created_at" => "2026-01-01T00:00:00Z"}]))
    assert {:ok, [%{"name" => "old"}]} = ClientTokens.list()
    {:ok, token} = ClientTokens.create("fresh", "read")
    assert {:ok, %{name: "fresh"}} = ClientTokens.authenticate_full(token)
  end
end
