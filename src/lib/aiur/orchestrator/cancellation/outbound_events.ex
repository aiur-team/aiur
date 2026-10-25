defmodule Aiur.Orchestrator.Cancellation.OutboundEvents do
  @moduledoc false

  alias Aiur.Events.Outbound.Producer
  alias Aiur.{Issue, JSONSafe, TrackerIdentity}

  @spec publish(map(), Issue.t()) :: :ok
  def publish(result, %Issue{} = issue) when is_map(result) do
    case Issue.tracker_identity(issue) do
      %TrackerIdentity{} = identity ->
        if TrackerIdentity.joinable?(identity) do
          topic = "ticket.#{identity.identifier}.cancel.result"
          Producer.maybe_publish(topic, payload(result), identity, nil, observed_at(result))
        else
          :ok
        end

      _unattributed ->
        :ok
    end
  end

  def publish(_result, _issue), do: :ok

  @doc false
  @spec payload(map()) :: map()
  def payload(result) do
    %{outbound_event: %{kind: :ticket_cancel_result, data: JSONSafe.normalize(result)}}
  end

  defp observed_at(result) do
    with value when is_binary(value) <- get_in(result, [:process, :observed_at]) || get_in(result, ["process", "observed_at"]),
         {:ok, observed_at, 0} <- DateTime.from_iso8601(value) do
      observed_at
    else
      _invalid -> nil
    end
  end
end
