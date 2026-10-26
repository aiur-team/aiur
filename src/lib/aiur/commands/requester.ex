defmodule Aiur.Commands.Requester do
  @moduledoc "Read request attribution with rollback-compatible defaults for v1 Commands."

  @spec executor_ticket_identifier() :: String.t()
  def executor_ticket_identifier, do: "executor"

  @spec kind(map()) :: :worker | :executor
  def kind(%{requester: %{kind: kind}}) when kind in [:worker, :executor], do: kind
  def kind(_decision), do: :worker

  @spec executor?(map()) :: boolean()
  def executor?(decision), do: kind(decision) == :executor

  @spec worker_ticket(map()) :: String.t() | nil
  def worker_ticket(decision) do
    if executor?(decision), do: nil, else: requester_ticket(decision)
  end

  @spec origin(map()) :: atom()
  def origin(%{origin: origin}) when not is_nil(origin), do: origin
  def origin(%{legacy_attention: attention}) when not is_nil(attention), do: :attention
  def origin(_decision), do: :emit_event

  @spec validate_ticket(map(), keyword()) :: :ok | {:error, term()}
  def validate_ticket(%{identifier: "executor"}, opts) do
    requester = Keyword.get(opts, :requester)

    if Keyword.get(opts, :legacy_replay, false) or executor_requester?(requester),
      do: :ok,
      else: {:error, {:ticket_identifier, :reserved}}
  end

  def validate_ticket(_ticket, _opts), do: :ok

  defp executor_requester?(%{kind: :executor}), do: true
  defp executor_requester?(%{"kind" => "executor"}), do: true
  defp executor_requester?(_requester), do: false

  defp requester_ticket(%{requester: %{ticket: ticket}}) when is_binary(ticket), do: ticket
  defp requester_ticket(%{ticket: %{identifier: identifier}}), do: identifier
end
