defmodule Aiur.Commands.Scope do
  @moduledoc """
  Ticket-scoped Command access grants for an embedding host application.

  A host application authenticates its own end user and asks Aiur for a
  short-lived grant naming the exact tickets (a game, a workspace) that user
  may see Commands for. The grant is an HMAC-signed bearer token: the host's
  service credential never reaches the end user, and Aiur never trusts a
  ticket set supplied by the caller of a read or answer operation.

  The token carries no Command data, so it cannot leak canonical state, and it
  is opaque to the host client. Verification is fail-closed: a missing,
  malformed, mis-signed, or expired token is an error, never an empty scope.
  """

  @prefix "cs1"
  @version 1
  @default_ttl_seconds 900
  @maximum_ttl_seconds 86_400
  @maximum_subject_bytes 200
  @maximum_ticket_bytes 200
  @maximum_tickets 500
  @minimum_secret_bytes 32

  @type t :: %{
          subject: String.t(),
          tickets: [String.t()],
          ticket_set: MapSet.t(String.t()),
          expires_at: DateTime.t()
        }

  @type verify_error :: :invalid_scope | :malformed | :invalid_signature | :expired | :invalid_ticket_scope

  @doc """
  Mints a signed grant for `subject` over an explicit ticket set.

  `opts` requires `:secret` (the instance's signing secret) and accepts
  `:expires_in` (seconds, default #{@default_ttl_seconds}) and `:now`.
  """
  @spec mint(String.t(), [String.t()], keyword()) ::
          {:ok, %{token: String.t(), scope: t()}} | {:error, :invalid_scope}
  def mint(subject, tickets, opts \\ []) do
    with {:ok, secret} <- secret(opts),
         {:ok, subject} <- normalize_subject(subject),
         {:ok, tickets} <- normalize_tickets(tickets),
         {:ok, ttl} <- ttl(opts) do
      now = now(opts)
      expires_at = DateTime.add(now, ttl, :second)

      payload = %{
        "v" => @version,
        "sub" => subject,
        "tickets" => tickets,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(expires_at)
      }

      body = encode_payload(payload)

      {:ok,
       %{
         token: Enum.join([@prefix, body, sign(body, secret)], "."),
         scope: %{subject: subject, tickets: tickets, ticket_set: MapSet.new(tickets), expires_at: expires_at}
       }}
    end
  end

  @doc "Verifies a bearer grant and returns the scope it authorizes."
  @spec verify(term(), keyword()) :: {:ok, t()} | {:error, verify_error()}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) do
    with {:ok, secret} <- secret(opts),
         {:ok, body} <- split(token),
         :ok <- check_signature(body, secret),
         {:ok, payload} <- decode_payload(body),
         {:ok, scope} <- normalize_payload(payload),
         :ok <- check_expiry(payload, opts) do
      {:ok, scope}
    end
  end

  def verify(_token, _opts), do: {:error, :malformed}

  @doc "The scoped ticket set as a map keyed for JSON components."
  @spec to_public(t()) :: map()
  def to_public(%{} = scope) do
    %{"kind" => "tickets", "label" => "Ticket-scoped Commands", "tickets" => scope.tickets}
  end

  defp secret(opts) do
    case Keyword.get(opts, :secret) do
      value when is_binary(value) and byte_size(value) >= @minimum_secret_bytes -> {:ok, value}
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp normalize_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    cond do
      trimmed == "" -> {:error, :invalid_scope}
      byte_size(trimmed) > @maximum_subject_bytes -> {:error, :invalid_scope}
      control_chars?(trimmed) -> {:error, :invalid_scope}
      true -> {:ok, trimmed}
    end
  end

  defp normalize_subject(_subject), do: {:error, :invalid_scope}

  defp normalize_tickets(tickets) when is_list(tickets) and tickets != [] do
    tickets
    |> Enum.reduce_while({:ok, []}, fn ticket, {:ok, acc} ->
      case normalize_ticket(ticket) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} ->
        values = acc |> Enum.reverse() |> Enum.uniq()

        if length(values) <= @maximum_tickets, do: {:ok, values}, else: {:error, :invalid_scope}

      :error ->
        {:error, :invalid_scope}
    end
  end

  defp normalize_tickets(_tickets), do: {:error, :invalid_scope}

  defp normalize_ticket(ticket) when is_binary(ticket) do
    trimmed = String.trim(ticket)

    cond do
      trimmed == "" -> :error
      byte_size(trimmed) > @maximum_ticket_bytes -> :error
      control_chars?(trimmed) -> :error
      true -> {:ok, trimmed}
    end
  end

  defp normalize_ticket(_ticket), do: :error

  defp ttl(opts) do
    case Keyword.get(opts, :expires_in, @default_ttl_seconds) do
      value when is_integer(value) and value > 0 and value <= @maximum_ttl_seconds -> {:ok, value}
      _invalid -> {:error, :invalid_scope}
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      _missing -> DateTime.utc_now()
    end
  end

  defp encode_payload(payload), do: payload |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp sign(body, secret), do: :crypto.mac(:hmac, :sha256, secret, sign_input(body)) |> Base.url_encode64(padding: false)

  defp sign_input(body), do: @prefix <> "." <> body

  defp split(token) do
    case String.split(token, ".") do
      [@prefix, body, signature] when body != "" and signature != "" -> {:ok, {body, signature}}
      _malformed -> {:error, :malformed}
    end
  end

  defp check_signature({body, signature}, secret) do
    expected = sign(body, secret)

    if Plug.Crypto.secure_compare(signature, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp decode_payload({body, _signature}) do
    with {:ok, json} <- Base.url_decode64(body, padding: false),
         {:ok, payload} when is_map(payload) <- Jason.decode(json) do
      {:ok, payload}
    else
      _invalid -> {:error, :malformed}
    end
  end

  defp normalize_payload(%{"v" => @version, "sub" => subject, "tickets" => tickets} = payload) do
    with {:ok, subject} <- normalize_subject(subject),
         {:ok, tickets} <- normalize_tickets(tickets),
         {:ok, iat} <- unix_seconds(Map.get(payload, "iat")),
         {:ok, exp} <- unix_seconds(Map.get(payload, "exp")),
         true <- exp > iat do
      {:ok, %{subject: subject, tickets: tickets, ticket_set: MapSet.new(tickets), expires_at: DateTime.from_unix!(exp)}}
    else
      _invalid -> {:error, :invalid_ticket_scope}
    end
  end

  defp normalize_payload(_payload), do: {:error, :invalid_ticket_scope}

  defp unix_seconds(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp unix_seconds(_value), do: :error

  defp check_expiry(%{"exp" => exp}, opts) when is_integer(exp) do
    if DateTime.to_unix(now(opts)) < exp, do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_payload, _opts), do: {:error, :invalid_ticket_scope}

  defp control_chars?(value), do: String.match?(value, ~r/[\x00-\x1F\x7F]/)
end
