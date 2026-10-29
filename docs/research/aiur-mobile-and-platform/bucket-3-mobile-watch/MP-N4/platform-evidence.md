# MP-N4 platform evidence

## E-C4 — OTP 28 push crypto primitives

Implementation: [#6754](https://github.com/aiur-team/aiur/issues/6754),
`Aiur.Push.Crypto.Primitives` in `src/lib/aiur/push/crypto/primitives.ex`.
The current toolchain pins OTP 28.5 and Elixir 1.19.5-otp-28 in `mise.toml`.
No additional Hex dependency is needed.

The runtime probe requires EDDH/X25519, EdDSA/Ed25519,
ChaCha20-Poly1305, HMAC and SHA-256. It queries each support category once per
cache fill and caches missing primitives in `:persistent_term`; injected probes
bypass that cache. HKDF is built from HMAC by the downstream HPKE implementation.

[OTP 28 crypto documentation](https://www.erlang.org/docs/28/apps/crypto/crypto.html)
exposes these primitives, subject to the linked libcrypto's support and FIPS mode.
The focused test checks the actual runtime and simulates each missing primitive,
including the ChaCha20-Poly1305 requirement. The guard reports gaps without
attempting encryption; HPKE vectors and capability reporting belong to later tickets.
