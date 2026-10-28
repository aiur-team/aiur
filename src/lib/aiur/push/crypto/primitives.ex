defmodule Aiur.Push.Crypto.Primitives do
  @moduledoc """
  Runtime support for the OTP 28 push suite: X25519, Ed25519,
  ChaCha20-Poly1305 and HMAC-SHA256 (including HKDF).

  Uses OTP's crypto application directly; linked libcrypto may omit primitives,
  for example in FIPS mode. See MP-N4 platform-evidence.md, E-C4 (#6754).
  The runtime result is cached for the lifetime of the VM.
  """

  @required [
    {:public_keys, :eddh},
    {:public_keys, :eddsa},
    {:curves, :x25519},
    {:curves, :ed25519},
    {:ciphers, :chacha20_poly1305},
    {:macs, :hmac},
    {:hashs, :sha256}
  ]
  @cache_key {__MODULE__, :missing}

  @doc "Returns the primitives unavailable in the running VM."
  @spec missing() :: [{atom(), atom()}]
  def missing do
    case :persistent_term.get(@cache_key, :not_cached) do
      :not_cached ->
        result = missing(&:crypto.supports/1)
        :persistent_term.put(@cache_key, result)
        result

      result ->
        result
    end
  end

  @doc "Checks an injected support provider without reading or writing the VM cache."
  @spec missing((atom() -> [atom()])) :: [{atom(), atom()}]
  def missing(supports_fun) do
    supported = Map.new(@required, fn {kind, _primitive} -> {kind, nil} end)
    supported = Map.new(supported, fn {kind, _} -> {kind, supports_fun.(kind)} end)
    Enum.reject(@required, fn {kind, primitive} -> primitive in Map.fetch!(supported, kind) end)
  end

  @doc "Whether the running VM supports every push primitive."
  @spec supported?() :: boolean()
  def supported?, do: missing() == []

  @doc "Checks an injected support provider without using the VM cache."
  @spec supported?((atom() -> [atom()])) :: boolean()
  def supported?(supports_fun), do: missing(supports_fun) == []
end
