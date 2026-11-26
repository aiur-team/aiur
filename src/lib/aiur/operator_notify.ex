defmodule Aiur.OperatorNotify do
  @moduledoc """
  Operator notifications: `operator.notify.<kind>` events that a host app turns
  into device pushes ("review ready", "#645 live", "#632 stalled").

  The topic family is exported, so with `events.export.enabled` a notification
  reaches events-feed subscribers and outbound webhooks. Aiur raises `stalled`
  itself when a ticket's agent or the dispatch cycle starts stalling.
  """

  alias Aiur.{AlertFeed, Events}

  @kinds ~w(review_ready live stalled info)
  @titles %{"review_ready" => "Review ready", "live" => "Live", "stalled" => "Stalled", "info" => "Info"}
  @ticket ~r/\A[A-Za-z0-9_-]+\z/
  @stall_topic ~r/\A(?:ticket\.([A-Za-z0-9_-]+)\.agent\.stalled|system\.dispatch\.cycle_stalled)\z/

  @type error :: :unknown_kind | :blank_text | :invalid_ticket | :invalid_url | {:publish_failed, term()}

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Publishes `operator.notify.<kind>` with `{title, body, ticket, url, created_at}`.

  `text` is the body. The title names the kind and, with `ticket:`, the ticket.
  `url:` must be an absolute http(s) URL.
  """
  @spec notify(String.t(), String.t(), keyword()) :: {:ok, pos_integer()} | {:error, error()}
  def notify(kind, text, opts \\ []) when is_binary(kind) and is_binary(text) and is_list(opts) do
    with :ok <- kind(kind),
         {:ok, body} <- body(text),
         {:ok, ticket} <- ticket(Keyword.get(opts, :ticket)),
         {:ok, url} <- url(Keyword.get(opts, :url)) do
      publish(kind, %{
        title: title(kind, ticket),
        body: body,
        ticket: ticket,
        url: url,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        source: :system
      })
    end
  end

  @doc """
  Runs `emit` for an alert and, when the alert opens a stall that was not
  already firing, publishes `operator.notify.stalled` once `emit` returns `:ok`.
  A stall alert repeated while the condition stays open notifies nobody.
  """
  @spec on_alert(String.t(), String.t() | nil, (-> result), keyword()) :: result when result: term()
  def on_alert(topic, message, emit, opts \\ []) when is_binary(topic) and is_function(emit, 0) do
    case Regex.run(@stall_topic, topic) do
      nil ->
        emit.()

      match ->
        opening? = condition_state(topic, opts) != :firing
        result = emit.()
        if result == :ok and opening?, do: notify_stalled(match, message)
        result
    end
  end

  defp notify_stalled(match, message) do
    text = if is_binary(message) and String.trim(message) != "", do: message, else: "Dispatch has stalled."
    _ = notify("stalled", text, ticket: Enum.at(match, 1))
    :ok
  end

  defp condition_state(topic, opts) do
    Keyword.get(opts, :condition_state, &AlertFeed.condition_state/1).(topic)
  rescue
    _unreadable -> :unknown
  end

  defp kind(kind) when kind in @kinds, do: :ok
  defp kind(_kind), do: {:error, :unknown_kind}

  defp body(text) do
    case String.trim(text) do
      "" -> {:error, :blank_text}
      body -> {:ok, body}
    end
  end

  defp ticket(nil), do: {:ok, nil}
  defp ticket(""), do: {:ok, nil}
  defp ticket(ticket) when is_integer(ticket) and ticket > 0, do: {:ok, Integer.to_string(ticket)}
  defp ticket(ticket) when is_binary(ticket), do: if(Regex.match?(@ticket, ticket), do: {:ok, ticket}, else: {:error, :invalid_ticket})
  defp ticket(_ticket), do: {:error, :invalid_ticket}

  defp url(nil), do: {:ok, nil}
  defp url(""), do: {:ok, nil}

  defp url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> {:ok, url}
      _invalid -> {:error, :invalid_url}
    end
  end

  defp url(_url), do: {:error, :invalid_url}

  defp title(kind, nil), do: @titles[kind]
  defp title(kind, ticket), do: "#{@titles[kind]}: #{ticket_label(ticket)}"

  defp ticket_label(ticket), do: if(Regex.match?(~r/\A\d+\z/, ticket), do: "#" <> ticket, else: ticket)

  defp publish(kind, payload) do
    case Events.publish("operator.notify.#{kind}", payload) do
      {:ok, id, _subscribers} -> {:ok, id}
      other -> {:error, {:publish_failed, other}}
    end
  rescue
    error -> {:error, {:publish_failed, error}}
  catch
    :exit, reason -> {:error, {:publish_failed, reason}}
  end
end
