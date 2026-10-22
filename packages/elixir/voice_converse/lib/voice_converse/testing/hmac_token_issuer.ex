defmodule VoiceConverse.Testing.HmacTokenIssuer do
  @moduledoc """
  Default `TokenIssuer`: HMAC-SHA256 signed tokens, `vct1.<payload>.<mac>` (base64url).

  The secret comes from `opts[:secret]` or, when absent, from `put_secret/1`
  (`:persistent_term`). It must be at least 32 bytes. TTLs are capped at 3,600 s so a
  token stays short-lived; the default is 300 s.
  """
  @behaviour VoiceConverse.Ports.TokenIssuer

  @key {__MODULE__, :secret}
  @prefix "vct1"
  @mac_bytes 32
  @min_secret_bytes 32
  @default_ttl_s 300
  @max_ttl_s 3_600

  @spec put_secret(binary()) :: :ok
  def put_secret(secret) when is_binary(secret), do: :persistent_term.put(@key, secret)

  @impl true
  def issue(scope, opts \\ []) when is_binary(scope) do
    ttl_s = Keyword.get(opts, :ttl_s, @default_ttl_s)

    with {:ok, secret} <- secret(opts),
         :ok <- check_ttl(ttl_s) do
      expires_at = DateTime.add(now(opts), ttl_s, :second)

      payload = %{
        "scope" => scope,
        "sub" => Keyword.get(opts, :subject),
        "exp" => DateTime.to_unix(expires_at),
        "nonce" => encode(:crypto.strong_rand_bytes(12))
      }

      body = @prefix <> "." <> encode(Jason.encode!(payload))
      {:ok, body <> "." <> encode(mac(secret, body)), DateTime.truncate(expires_at, :second)}
    end
  end

  @impl true
  def verify(token, scope, opts \\ [])

  def verify(token, scope, opts) when is_binary(token) and is_binary(scope) do
    with {:ok, secret} <- secret(opts),
         {:ok, body, given} <- split(token),
         true <- :crypto.hash_equals(mac(secret, body), given),
         {:ok, payload} <- decode_payload(body) do
      check_claims(payload, scope, now(opts))
    else
      _ -> {:error, :invalid}
    end
  end

  def verify(_token, _scope, _opts), do: {:error, :invalid}

  defp check_claims(%{"scope" => scope} = payload, scope, now) do
    expires_at = DateTime.from_unix!(payload["exp"])

    if DateTime.compare(now, expires_at) == :lt,
      do: {:ok, %{scope: scope, subject: payload["sub"], expires_at: expires_at}},
      else: {:error, :expired}
  end

  defp check_claims(_payload, _scope, _now), do: {:error, :wrong_scope}

  defp split(token) do
    with [@prefix, payload, mac] <- String.split(token, ".", parts: 3),
         {:ok, given} when byte_size(given) == @mac_bytes <- decode(mac) do
      {:ok, @prefix <> "." <> payload, given}
    end
  end

  defp decode_payload(@prefix <> "." <> payload) do
    with {:ok, json} <- decode(payload),
         {:ok, %{"scope" => scope, "exp" => exp} = claims}
         when is_binary(scope) and is_integer(exp) <- Jason.decode(json) do
      {:ok, claims}
    end
  end

  defp secret(opts) do
    case Keyword.get(opts, :secret) || :persistent_term.get(@key, nil) do
      secret when is_binary(secret) and byte_size(secret) >= @min_secret_bytes -> {:ok, secret}
      nil -> {:error, :no_secret}
      _ -> {:error, :weak_secret}
    end
  end

  defp check_ttl(ttl_s) when is_integer(ttl_s) and ttl_s > 0 and ttl_s <= @max_ttl_s, do: :ok
  defp check_ttl(_), do: {:error, :invalid_ttl}

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
  defp mac(secret, body), do: :crypto.mac(:hmac, :sha256, secret, body)
  defp encode(bin), do: Base.url_encode64(bin, padding: false)
  defp decode(text), do: Base.url_decode64(text, padding: false)
end
