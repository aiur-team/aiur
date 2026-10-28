defmodule Aiur.Push.Crypto.PrimitivesTest do
  use ExUnit.Case, async: false

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

  test "caches the runtime result and keeps injected probes isolated" do
    assert Primitives.missing() == []
    assert :persistent_term.get(@cache_key, :not_cached) == []
    assert Primitives.missing(fn _ -> [] end) == @required
    assert Primitives.missing() == []
    assert Primitives.supported?()
    assert :persistent_term.get(@cache_key) == []
  end
end
