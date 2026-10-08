defmodule Aiur.Executor.ClaimsTest do
  use Aiur.TestSupport

  alias Aiur.Executor.Claims

  setup do
    root = Aiur.TestSupport.tmp_root!("aiur-executor-claims")
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

  test "takeover demotes the expired owner and renewal stays read-only", %{opts: opts} do
    past = DateTime.add(DateTime.utc_now(), -2 * Claims.lease_ttl_ms(), :millisecond)
    {:ok, _} = Claims.claim("agent-a", Keyword.put(opts, :now, past))
    assert {:ok, %{"id" => "agent-b", "role" => "owner"}} = Claims.claim("agent-b", opts)
    assert Enum.find(Claims.entries(opts), &(&1["id"] == "agent-a"))["role"] == "observer"
    assert {:ok, %{"role" => "observer"}} = Claims.renew("agent-a", opts)
    assert {:error, {:not_owner, %{"id" => "agent-b"}}} = Claims.record_acknowledgement("agent-a", 1, opts)
    assert Enum.count(Claims.entries(opts), &(&1["role"] == "owner" and Claims.live?(&1, DateTime.utc_now()))) == 1
  end

  test "expired legacy owner cannot renew while a successor owns the stream", %{opts: opts} do
    past = DateTime.add(DateTime.utc_now(), -2 * Claims.lease_ttl_ms(), :millisecond)
    {:ok, expired} = Claims.claim("agent-a", Keyword.put(opts, :now, past))
    {:ok, successor} = Claims.claim("agent-b", opts)
    Aiur.JsonStore.write!(opts[:path], %{"consumers" => %{"agent-a" => expired, "agent-b" => successor}})
    assert {:error, :not_owner} = Claims.renew("agent-a", opts)
    assert Enum.find(Claims.entries(opts), &(&1["id"] == "agent-a")) == expired
    assert {:ok, ^successor} = Claims.owner(opts)
  end

  test "observer renewal extends its lease (compatibility guard)", %{opts: opts} do
    now = DateTime.utc_now()
    {:ok, observer} = Claims.observe("observer", Keyword.put(opts, :now, now))
    {:ok, _} = Claims.claim("owner", Keyword.put(opts, :now, now))
    assert {:ok, renewed} = Claims.renew("observer", Keyword.put(opts, :now, DateTime.add(now, 1)))
    assert renewed["role"] == "observer"
    assert renewed["lease_expires_at"] > observer["lease_expires_at"]
  end

  @tag capture_log: true
  test "legacy acknowledgement and revoke select latest claim then id", %{opts: opts} do
    now = DateTime.utc_now()
    {:ok, older} = Claims.claim("agent-z", Keyword.put(opts, :now, now))
    newer = older |> Map.put("id", "agent-a") |> Map.put("claimed_at", DateTime.to_iso8601(DateTime.add(now, 1)))

    for candidate <- [newer, Map.put(newer, "claimed_at", older["claimed_at"])] do
      winner = if candidate["claimed_at"] == older["claimed_at"], do: "agent-z", else: "agent-a"
      loser = if winner == "agent-z", do: "agent-a", else: "agent-z"

      for _ <- 1..20 do
        Aiur.JsonStore.write!(opts[:path], %{"consumers" => %{"agent-z" => older, "agent-a" => candidate}})
        assert {:ok, %{"id" => ^winner}} = Claims.owner(opts)
        assert {:error, {:not_owner, %{"id" => ^winner}}} = Claims.record_acknowledgement(loser, 1, opts)
        assert {:ok, %{"id" => ^winner, "cursor_at_last_ack" => 2}} = Claims.record_acknowledgement(winner, 2, opts)
        assert {:error, :not_owner} = Claims.revoke(loser, opts)
        assert {:ok, %{"id" => ^winner, "role" => "revoked"}} = Claims.revoke(winner, opts)
      end
    end
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

  describe "lock_retry_budget/0" do
    test "publishes the bounds a contention diagnostic reports" do
      budget = Claims.lock_retry_budget()

      assert budget.timeout_ms == 5_000
      assert budget.retry_interval_ms == 25
      assert budget.stale_after_seconds == 60
      assert budget.timeout_ms <= Claims.call_timeout_ms()
    end

    test "clamps an override above the surrounding call budget (#2600)" do
      # A lock wait longer than the call budget would expire the caller before
      # the wait could ever return a `claim`-stage reason.
      with_app_env(:executor_claims_lock_timeout_ms, Claims.call_timeout_ms() * 2, fn ->
        assert Claims.lock_retry_budget().timeout_ms == Claims.call_timeout_ms()
      end)
    end

    test "falls back to the default when the override is not a positive integer (#2600)" do
      # A non-integer would make the retry guard fall straight through to
      # "timed out" without retrying once.
      for invalid <- [0, -1, "5000", nil] do
        with_app_env(:executor_claims_lock_timeout_ms, invalid, fn ->
          assert Claims.lock_retry_budget().timeout_ms == 5_000
        end)
      end
    end
  end

  defp with_app_env(key, value, fun) do
    previous = Application.fetch_env(:aiur, key)
    Application.put_env(:aiur, key, value)

    try do
      fun.()
    after
      case previous do
        {:ok, restored} -> Application.put_env(:aiur, key, restored)
        :error -> Application.delete_env(:aiur, key)
      end
    end
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
