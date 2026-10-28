defmodule Aiur.Push.Crypto.PrimitivesTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Push.Crypto.Primitives

  @required [
    {:public_keys, :eddh},
    {:public_keys, :eddsa},
    {:curves, :x25519},
    {:curves, :ed25519},
    {:ciphers, :chacha20_poly1305},
    {:macs, :hmac},
    {:hashs, :sha256}
  ]
  @cache_key {Primitives, :missing}

  setup do
    original = :persistent_term.get(@cache_key, :not_cached)
    :persistent_term.erase(@cache_key)

    on_exit(fn ->
      if original == :not_cached,
        do: :persistent_term.erase(@cache_key),
        else: :persistent_term.put(@cache_key, original)
    end)
  end

  test "the pinned OTP provides every push primitive" do
    assert Primitives.missing() == []
    assert Primitives.supported?()
  end

  test "reports every required primitive when libcrypto provides nothing" do
    assert Primitives.missing(fn _ -> [] end) == @required
  end

  test "reports each missing primitive and rejects the incomplete suite" do
    for {missing_kind, missing_primitive} = gap <- @required do
      supports = fn kind ->
        for {^kind, primitive} <- @required,
            {kind, primitive} != {missing_kind, missing_primitive},
            do: primitive
      end

      assert Primitives.missing(supports) == [gap]
      refute Primitives.supported?(supports)
    end
  end

  test "reads each support category once and accepts a complete suite" do
    supports = fn kind ->
      Process.put(kind, Process.get(kind, 0) + 1)
      for {^kind, primitive} <- @required, do: primitive
    end

    assert Primitives.missing(supports) == []
    for kind <- [:public_keys, :curves, :ciphers, :macs, :hashs], do: assert(Process.get(kind) == 1)
    assert Primitives.supported?(fn kind -> for {^kind, primitive} <- @required, do: primitive end)
  end

  test "cached gaps reach both zero-arity guard functions" do
    gaps = [{:curves, :x25519}]
    :persistent_term.put(@cache_key, gaps)

    assert Primitives.missing() == gaps
    refute Primitives.supported?()
  end

  test "the cold runtime path calls crypto supports once per category and then reuses the cache" do
    probe = start_supervised!({Agent, fn -> nil end})
    session = :trace.session_create(:push_crypto_probe, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)
    :trace.function(session, {:crypto, :supports, 1}, true, [:local])
    :trace.process(session, probe, true, [:call])

    assert {[], []} == Agent.get(probe, fn _ -> {Primitives.missing(), Primitives.missing()} end)
    delivery = :trace.delivered(session, probe)
    receive_barrier({:trace_delivered, ^probe, ^delivery})

    for kind <- [:public_keys, :curves, :ciphers, :macs, :hashs] do
      assert_received {:trace, ^probe, :call, {:crypto, :supports, [^kind]}}
    end

    refute_received {:trace, ^probe, :call, {:crypto, :supports, _}}
  end

  test "caches the runtime result and keeps injected probes isolated" do
    assert Primitives.missing() == []
    assert :persistent_term.get(@cache_key, :not_cached) == []
    assert Primitives.missing(fn _ -> [] end) == @required
    assert Primitives.missing() == []
    assert Primitives.supported?()
    assert :persistent_term.get(@cache_key) == []
  end
end
