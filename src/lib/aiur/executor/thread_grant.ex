defmodule Aiur.Executor.ThreadGrant do
  @moduledoc """
  Short-lived grants that let an embedding host read and post to the
  operator↔Executor thread.

  The host's server swaps the instance supervisor credential for a grant naming
  its user, and hands only the grant to the browser. A grant reaches the
  Executor thread and nothing else: no worker conversation, no Command. It is an
  HMAC-signed bearer token; verification is fail-closed.
  """

  @prefix "et1"
  @version 1
  @default_ttl_seconds 900
  @maximum_ttl_seconds 86_400
  @maximum_subject_bytes 200
  @minimum_secret_bytes 32

  @type t :: %{subject: String.t(), expires_at: DateTime.t()}

  @doc "Whether `token` has the grant's shape, so other bearer credentials can be told apart."
  @spec grant?(term()) :: boolean()
  def grant?(token), do: is_binary(token) and String.starts_with?(token, @prefix <> ".")

  @doc "Mints a grant for `subject`. Requires `:secret`; accepts `:expires_in` seconds (default #{@default_ttl_seconds}) and `:now`."
  @spec mint(term(), keyword()) :: {:ok, %{token: String.t(), grant: t()}} | {:error, :invalid_grant}
  def mint(subject, opts) do
    with {:ok, secret} <- secret(opts),
         {:ok, subject} <- subject(subject),
         {:ok, ttl} <- ttl(Keyword.get(opts, :expires_in, @default_ttl_seconds)) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      expires_at = now |> DateTime.add(ttl, :second) |> DateTime.truncate(:second)
      body = Base.url_encode64(Jason.encode!(%{"v" => @version, "sub" => subject, "exp" => DateTime.to_unix(expires_at)}), padding: false)

      {:ok, %{token: Enum.join([@prefix, body, sign(body, secret)], "."), grant: %{subject: subject, expires_at: expires_at}}}
    end
  end

  @doc "Verifies a grant. Requires `:secret`; accepts `:now`."
  @spec verify(term(), keyword()) :: {:ok, t()} | {:error, :malformed | :invalid_signature | :expired | :invalid_grant}
  def verify(token, opts) when is_binary(token) do
    with {:ok, secret} <- secret(opts),
         [@prefix, body, signature] <- String.split(token, "."),
         true <- Plug.Crypto.secure_compare(sign(body, secret), signature) || {:error, :invalid_signature},
         {:ok, json} <- Base.url_decode64(body, padding: false),
         {:ok, %{"v" => @version, "sub" => subject, "exp" => exp}} when is_binary(subject) and is_integer(exp) <- Jason.decode(json),
         {:ok, expires_at} <- DateTime.from_unix(exp) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      if DateTime.compare(now, expires_at) == :lt, do: {:ok, %{subject: subject, expires_at: expires_at}}, else: {:error, :expired}
    else
      {:error, reason} when reason in [:invalid_signature, :invalid_grant] -> {:error, reason}
      _malformed -> {:error, :malformed}
    end
  end

  def verify(_token, _opts), do: {:error, :malformed}

  defp sign(body, secret), do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.url_encode64(padding: false)

  defp secret(opts) do
    case Keyword.get(opts, :secret) do
      secret when is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes -> {:ok, secret}
      _missing -> {:error, :invalid_grant}
    end
  end

  defp subject(subject) when is_binary(subject) do
    subject = String.trim(subject)

    if subject != "" and byte_size(subject) <= @maximum_subject_bytes and not String.match?(subject, ~r/[[:cntrl:]]/u),
      do: {:ok, subject},
      else: {:error, :invalid_grant}
  end

  defp subject(_subject), do: {:error, :invalid_grant}

  defp ttl(ttl) when is_integer(ttl) and ttl > 0 and ttl <= @maximum_ttl_seconds, do: {:ok, ttl}
  defp ttl(_ttl), do: {:error, :invalid_grant}
end
