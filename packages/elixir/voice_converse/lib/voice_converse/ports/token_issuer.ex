defmodule VoiceConverse.Ports.TokenIssuer do
  @moduledoc """
  Optional port: short-lived transport tokens the host mints and checks itself, so a host that
  embeds voice in its own app does not depend on a dashboard session or one static token.

  A token carries a scope (what it may open, e.g. `"converse"`) and an expiry. `verify/3` returns
  `{:ok, claims}` only for an untampered token of the expected scope that has not expired. The
  error is one of three reasons and never echoes the token:

    * `:expired` - the token was genuine but its expiry has passed (the expiry is exclusive)
    * `:wrong_scope` - the token was genuine but minted for another scope
    * `:invalid` - malformed, tampered with, or signed by someone else

  Implementations compare MACs in constant time and never log or keep token values. Calls go
  through `VoiceConverse.Ports.call_port/4` with the `:token` deadline. Both callbacks take
  `:instance` (the `Config.name`) and `:now` (a `DateTime`, so expiry is checked against an
  injected clock) in `opts`. Secrets never travel in `opts`. `VoiceConverse.TokenIssuer.Hmac` is
  the shipped default.
  """

  @type scope :: String.t()
  @type claims :: %{scope: scope(), subject: String.t() | nil, expires_at: DateTime.t()}
  @type verify_error :: :expired | :wrong_scope | :invalid

  @doc "Mints a token for `scope`. Options: `:ttl_s`, `:subject`, `:instance`, `:now`."
  @callback issue(scope(), opts :: keyword()) ::
              {:ok, token :: String.t(), expires_at :: DateTime.t()} | {:error, term()}

  @doc "Checks `token` against the scope the caller expects. Options: `:instance`, `:now`."
  @callback verify(token :: String.t(), scope(), opts :: keyword()) ::
              {:ok, claims()} | {:error, verify_error()}
end
