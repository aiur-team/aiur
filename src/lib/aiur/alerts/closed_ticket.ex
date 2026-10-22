defmodule Aiur.Alerts.ClosedTicket do
  @moduledoc """
  Resolves every open attention of a closed ticket (#5867). Nobody can act on
  a closed ticket's attention, so leaving it open only buries the live ones.
  """

  alias Aiur.{AlertFeed, AlertLedger}

  @ledger_opts [:ledger_path, :ledger_paths, :log_roots]

  @doc "Appends a quiet `.resolved` record for each open `ticket.<id>.*` attention of `tickets`."
  @spec resolve([String.t()], keyword()) :: :ok
  def resolve(tickets, opts \\ [])
  def resolve([], _opts), do: :ok

  def resolve(tickets, opts) when is_list(tickets) do
    tickets = MapSet.new(tickets, &to_string/1)
    ledger_opts = Keyword.take(opts, @ledger_opts)
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.to_iso8601()

    [{:needs_attention, true} | ledger_opts]
    |> AlertFeed.list()
    |> Enum.map(& &1["topic"])
    |> Enum.uniq()
    |> Enum.each(fn topic ->
      with "ticket." <> rest <- topic,
           [ticket, _] <- String.split(rest, ".", parts: 2),
           true <- MapSet.member?(tickets, ticket) do
        AlertLedger.append(resolution(topic, ticket, now), ledger_opts)
      end
    end)
  end

  defp resolution(topic, ticket, now) do
    %{
      "event" => "alert",
      "timestamp" => now,
      "topic" => topic <> ".resolved",
      "name" => topic <> ".resolved",
      "source_ticket_id" => ticket,
      "message" => "Ticket #{ticket} is closed; its open attention is resolved.",
      "reason" => "The ticket reached a terminal state.",
      "severity" => "info",
      "needs_attention" => false,
      "agent" => "system"
    }
  end
end
