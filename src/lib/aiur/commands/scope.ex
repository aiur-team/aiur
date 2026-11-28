defmodule Aiur.Commands.Scope do
  @moduledoc """
  Ticket-scoped Command access grants for an embedding host application.

  A host application authenticates its own end user and asks Aiur for a
  short-lived grant naming the exact tickets (a game, a workspace) or the ticket
  labels that user may see Commands for. The grant is an HMAC-signed bearer
  token: the host's service credential never reaches the end user, and Aiur
  never trusts a ticket set supplied by the caller of a read or answer
  operation.

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
  @maximum_labels 50
  @maximum_label_bytes 200
  @label_pattern ~r/^[a-z0-9][a-z0-9_-]{0,63}:[a-z0-9][a-z0-9._-]{0,127}$/
  @minimum_secret_bytes 32

  @type t :: %{
          subject: String.t(),
          tickets: [String.t()],
          ticket_set: MapSet.t(String.t()),
          labels: [String.t()],
          label_set: MapSet.t(String.t()),
          build_order: %{kind: :feature | :epic, key: String.t()} | nil,
          expires_at: DateTime.t()
        }

  @type verify_error :: :invalid_scope | :malformed | :invalid_signature | :expired | :invalid_ticket_scope

  @doc """
  Mints a signed grant for `subject` over an explicit ticket set.

  `opts` requires `:secret` (the instance's signing secret) and accepts
  `:expires_in` (seconds, default #{@default_ttl_seconds}), `:now`, and
  `:labels` for a label scope such as `["game:chess"]`. A grant without any
  ticket and without any label authorizes nothing and is rejected.
  """
  @spec mint(String.t(), [String.t()], keyword()) ::
          {:ok, %{token: String.t(), scope: t()}} | {:error, :invalid_scope}
  def mint(subject, tickets, opts \\ []) do
    with {:ok, secret} <- secret(opts),
         {:ok, subject} <- normalize_subject(subject),
         {:ok, tickets} <- normalize_tickets(tickets),
         {:ok, labels} <- normalize_labels(Keyword.get(opts, :labels, [])),
         {:ok, build_order} <- normalize_build_order(Keyword.get(opts, :build_order)),
         :ok <- require_scope_mode(tickets, labels, build_order),
         {:ok, ttl} <- ttl(opts) do
      now = now(opts)
      expires_at = DateTime.add(now, ttl, :second)

      payload = %{
        "v" => @version,
        "sub" => subject,
        "tickets" => tickets,
        "labels" => labels,
        "build_order" => encode_build_order(build_order),
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(expires_at)
      }

      body = encode_payload(payload)

      {:ok,
       %{
         token: Enum.join([@prefix, body, sign(body, secret)], "."),
         scope: Map.put(scope(subject, tickets, labels, expires_at), :build_order, build_order)
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

  @doc "The verified grant scope as a map for JSON components."
  @spec to_public(t()) :: map()
  def to_public(%{} = scope) do
    public = %{"kind" => if(scope.build_order, do: "build_order", else: "tickets"), "label" => if(scope.build_order, do: "Build Order", else: "Ticket-scoped Commands"), "tickets" => scope.tickets}

    public
    |> maybe_put("labels", Map.get(scope, :labels, []))
    |> maybe_put("build_order", encode_build_order(Map.get(scope, :build_order)))
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

  defp normalize_tickets(tickets) when is_list(tickets) do
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
      # Command ticket identifiers are matched case-insensitively, so a grant
      # stores the canonical lower-case form and cannot miss on case alone.
      true -> {:ok, String.downcase(trimmed)}
    end
  end

  defp normalize_ticket(_ticket), do: :error

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, acc} ->
      case normalize_label(label) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} ->
        values = acc |> Enum.reverse() |> Enum.uniq()

        if length(values) <= @maximum_labels, do: {:ok, values}, else: {:error, :invalid_scope}

      :error ->
        {:error, :invalid_scope}
    end
  end

  defp normalize_labels(_labels), do: {:error, :invalid_scope}

  defp normalize_label(label) when is_binary(label) and byte_size(label) <= @maximum_label_bytes do
    value = label |> String.trim() |> String.downcase()

    if String.valid?(value) and Regex.match?(@label_pattern, value), do: {:ok, value}, else: :error
  end

  defp normalize_label(_label), do: :error

  defp require_scope_mode([], [], %{kind: kind, key: _key}) when kind in [:feature, :epic], do: :ok
  defp require_scope_mode(tickets, labels, nil) when tickets != [] or labels != [], do: :ok
  defp require_scope_mode(_tickets, _labels, _scope), do: {:error, :invalid_scope}

  defp normalize_build_order(nil), do: {:ok, nil}

  defp normalize_build_order(%{kind: kind, key: key}), do: normalize_build_order(%{"kind" => kind, "key" => key})

  defp normalize_build_order(%{"kind" => kind, "key" => key}) when kind in ["feature", "epic"] do
    if valid_build_order_key?(key), do: {:ok, %{kind: String.to_existing_atom(kind), key: key}}, else: {:error, :invalid_scope}
  rescue
    ArgumentError -> {:error, :invalid_scope}
  end

  defp normalize_build_order(_scope), do: {:error, :invalid_scope}

  defp valid_build_order_key?(key) when is_binary(key) and byte_size(key) <= 128 do
    String.valid?(key) and String.trim(key) == key and key != "" and not control_chars?(key)
  end

  defp valid_build_order_key?(_key), do: false

  defp encode_build_order(nil), do: nil
  defp encode_build_order(%{kind: kind, key: key}), do: %{"kind" => Atom.to_string(kind), "key" => key}

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp scope(subject, tickets, labels, expires_at) do
    %{
      subject: subject,
      tickets: tickets,
      ticket_set: MapSet.new(tickets),
      labels: labels,
      label_set: MapSet.new(labels),
      build_order: nil,
      expires_at: expires_at
    }
  end

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
         {:ok, labels} <- normalize_labels(Map.get(payload, "labels", [])),
         {:ok, build_order} <- normalize_build_order(Map.get(payload, "build_order")),
         :ok <- require_scope_mode(tickets, labels, build_order),
         {:ok, iat} <- unix_seconds(Map.get(payload, "iat")),
         {:ok, exp} <- unix_seconds(Map.get(payload, "exp")),
         true <- exp > iat do
      {:ok, Map.put(scope(subject, tickets, labels, DateTime.from_unix!(exp)), :build_order, build_order)}
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
