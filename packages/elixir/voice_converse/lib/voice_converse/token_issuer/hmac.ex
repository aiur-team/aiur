defmodule VoiceConverse.TokenIssuer.Hmac do
  @moduledoc """
  Shipped default `VoiceConverse.Ports.TokenIssuer`: HMAC-SHA256 signed tokens,
  `vct1.<payload>.<mac>` (base64url).

  The host installs the secret once per instance with `put_secret/2`, as a binary of at least
  32 bytes or a zero-arity function returning one (read at the moment of use). The secret never
  travels in call arguments, so a crash report cannot print it. Callbacks pick the instance with
  `opts[:instance]` (default `VoiceConverse`, the default `Config.name`).

  TTLs default to 300 s and are capped at 3,600 s so a token stays short-lived. Verifying with no
  secret installed fails closed (`:invalid`) and logs a warning naming the instance, never the
  token.
  """
  @behaviour VoiceConverse.Ports.TokenIssuer

  require Logger

  @prefix "vct1"
  @mac_bytes 32
  @min_secret_bytes 32
  @default_ttl_s 300
  @max_ttl_s 3_600

  @doc "Installs the signing secret for `instance`."
  @spec put_secret(term(), binary() | (-> binary())) :: :ok | {:error, :weak_secret}
  def put_secret(instance, secret) when is_function(secret, 0), do: store(instance, secret)

  def put_secret(instance, secret) when is_binary(secret) do
    if byte_size(secret) >= @min_secret_bytes,
      do: store(instance, secret),
      else: {:error, :weak_secret}
  end

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
      {:error, reason} when reason in [:no_secret, :weak_secret] ->
        Logger.warning("voice token issuer: #{reason} for instance #{inspect(instance(opts))}")
        {:error, :invalid}

      _ ->
        {:error, :invalid}
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

  defp store(instance, secret), do: :persistent_term.put(key(instance), secret)

  defp secret(opts) do
    case :persistent_term.get(key(instance(opts)), nil) do
      nil -> {:error, :no_secret}
      fun when is_function(fun, 0) -> check_secret(fun.())
      secret -> check_secret(secret)
    end
  end

  defp check_secret(secret) when is_binary(secret) and byte_size(secret) >= @min_secret_bytes,
    do: {:ok, secret}

  defp check_secret(_), do: {:error, :weak_secret}

  defp check_ttl(ttl_s) when is_integer(ttl_s) and ttl_s > 0 and ttl_s <= @max_ttl_s, do: :ok
  defp check_ttl(_), do: {:error, :invalid_ttl}

  defp key(instance), do: {__MODULE__, :secret, instance}
  defp instance(opts), do: Keyword.get(opts, :instance, VoiceConverse)
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
  defp mac(secret, body), do: :crypto.mac(:hmac, :sha256, secret, body)
  defp encode(bin), do: Base.url_encode64(bin, padding: false)
  defp decode(text), do: Base.url_decode64(text, padding: false)
end
