defmodule Aiur.Executor.ClaimsTest do
  use Aiur.TestSupport

  alias Aiur.Executor.Claims

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-executor-claims-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [path: Path.join(root, "claims.json")]}
  end

  test "auto-claims when nobody holds the stream", %{opts: opts} do
    assert {:ok, entry} = Claims.claim("agent-a", opts)
    assert entry["role"] == "owner"
    assert {:ok, %{"id" => "agent-a"}} = Claims.owner(opts)
  end

  test "refuses a takeover from a live, renewing owner and names it", %{opts: opts} do
    {:ok, _entry} = Claims.claim("agent-a", opts)

    assert {:error, {:held_by, owner}} = Claims.claim("agent-b", opts)
    assert owner["id"] == "agent-a"
    assert is_binary(owner["last_renewed_at"])
    assert is_binary(owner["host"])
  end

  test "a lapsed lease expires with no operator action and a successor takes over", %{opts: opts} do
    past = DateTime.add(DateTime.utc_now(), -10 * Claims.lease_ttl_ms(), :millisecond)
    {:ok, _entry} = Claims.claim("agent-a", Keyword.put(opts, :now, past))

    # No revoke, no release, no operator step: only the passage of time.
    assert :none == Claims.owner(opts)
    assert {:ok, %{"id" => "agent-b", "role" => "owner"}} = Claims.claim("agent-b", opts)
  end

  test "revoking a live owner is explicit and must name that owner", %{opts: opts} do
    {:ok, _entry} = Claims.claim("agent-a", opts)

    assert {:error, :not_owner} = Claims.revoke("agent-b", opts)
    assert {:ok, %{"id" => "agent-a"}} = Claims.owner(opts)

    assert {:ok, _revoked} = Claims.revoke("agent-a", opts)
    assert :none == Claims.owner(opts)
    assert {:ok, %{"id" => "agent-b"}} = Claims.claim("agent-b", opts)
  end

  test "releasing frees the stream immediately", %{opts: opts} do
    {:ok, _entry} = Claims.claim("agent-a", opts)
    assert :ok = Claims.release("agent-a", opts)
    assert :none == Claims.owner(opts)
  end

  test "an observer never becomes the owner", %{opts: opts} do
    {:ok, _entry} = Claims.claim("agent-a", opts)
    {:ok, observer} = Claims.observe("agent-b", opts)

    assert observer["role"] == "observer"
    assert {:ok, %{"id" => "agent-a"}} = Claims.owner(opts)
    assert length(Claims.entries(opts)) == 2
  end

  test "consumer identity is explicit and never inferred from the environment" do
    assert Claims.resolve_consumer_id(as: "agent-a") == "agent-a"
    assert Claims.resolve_consumer_id(as: "agent a/b") == "agent_a_b"

    with_env("AIUR_EXECUTOR_ID", "from-env", fn ->
      assert Claims.resolve_consumer_id([]) == "from-env"
      assert Claims.resolve_consumer_id(as: "explicit") == "explicit"
    end)
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end
end
