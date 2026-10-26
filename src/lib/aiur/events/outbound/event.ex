defmodule Aiur.Events.Outbound.Event do
  @moduledoc "Normalizes allowlisted internal facts into versioned outbound event maps."
  # aiur:event-bus-boundary-member

  alias Aiur.{TicketObservation, TrackerIdentity}

  @progress_sources ["progress", "progress.checkin", "progress.phase"]
  @lifecycles ["queued", "retrying", "allocated", "running", "paused", "waiting", "replaced", "completed", "cancelled"]
  @lifecycle_sources ["status_report", "tracker"]
  @token_fields ["input", "cached_input", "cache_creation_input", "output", "reasoning_output", "provider_reported_total"]
  @money_fields ["amount", "currency", "unit", "measurement_kind", "counter_scope", "source", "source_version"]
  @spend_cap_fields [
    "contract",
    "contract_version",
    "schema_version",
    "job_id",
    "ticket",
    "currency",
    "cap_amount",
    "spent_amount",
    "remaining_amount",
    "state",
    "end_state",
    "coverage",
    "authority",
    "configured_at",
    "reached_at"
  ]
  @cancel_fields ["contract", "contract_version", "issue_identifier", "tracker_state", "process"]
  @cancel_exit_statuses ["normal", "shutdown", "killed", "noproc", "unknown"]
  @decimal ~r/^[0-9]+(?:\.[0-9]+)?$/

  @doc "Returns whether an internal topic can produce a versioned external event."
  @spec exportable_topic?(String.t()) :: boolean()
  def exportable_topic?(topic) when is_binary(topic) do
    case String.split(topic, ".") do
      ["ticket", _identifier, "lifecycle", "changed"] -> true
      ["ticket", _identifier, "usage", "changed"] -> true
      ["ticket", _identifier, "usage", "spend_cap_reached"] -> true
      ["ticket", _identifier, "cancel", "result"] -> true
      ["ticket", _identifier, "agent", "progress"] -> true
      ["ticket", _identifier, "agent", "progress", suffix] when suffix in ["checkin", "phase"] -> true
      _other -> false
    end
  end

  def exportable_topic?(_topic), do: false

  @spec normalize(map(), DateTime.t()) :: {:ok, map()} | :drop
  def normalize(
        %{
          id: id,
          topic: topic,
          outbound_event: %{kind: :ticket_lifecycle, data: data},
          ticket_observation: %TicketObservation{} = observation
        },
        %DateTime{} = emitted_at
      ) do
    with {:ok, identity, job_id} <- correlation(observation, id),
         true <- topic == "ticket.#{identity.identifier}.lifecycle.changed",
         {:ok, data} <- lifecycle_data(data),
         {:ok, envelope} <- envelope("aiur.ticket_lifecycle_event", "ticket.lifecycle.changed", id, emitted_at, identity, job_id) do
      {:ok, Map.put(envelope, "data", data)}
    else
      _invalid -> :drop
    end
  end

  def normalize(
        %{
          "contract" => "aiur.ticket_spend_cap_reached",
          id: id,
          topic: topic,
          ticket_observation: %TicketObservation{} = observation
        } = event,
        %DateTime{} = emitted_at
      ) do
    with {:ok, identity, job_id} <- correlation(observation, id),
         true <- topic == "ticket.#{identity.identifier}.usage.spend_cap_reached",
         {:ok, data} <- spend_cap_data(event, identity),
         {:ok, envelope} <- envelope("aiur.ticket_spend_cap_reached", "ticket.spend_cap.reached", id, emitted_at, identity, job_id) do
      {:ok, Map.merge(data, envelope)}
    else
      _invalid -> :drop
    end
  end

  def normalize(
        %{
          id: id,
          topic: topic,
          outbound_event: %{kind: :ticket_cancel_result, data: data},
          ticket_observation: %TicketObservation{} = observation
        },
        %DateTime{} = emitted_at
      ) do
    with {:ok, identity, job_id} <- correlation(observation, id),
         true <- topic == "ticket.#{identity.identifier}.cancel.result",
         {:ok, data} <- cancel_result_data(data, identity),
         {:ok, envelope} <- envelope("aiur.ticket_cancel", "ticket.cancel.result", id, emitted_at, identity, job_id) do
      {:ok, Map.merge(data, envelope)}
    else
      _invalid -> :drop
    end
  end

  def normalize(
        %{
          id: id,
          topic: topic,
          ticket_observation: %TicketObservation{source: %{kind: :agent_event}} = observation
        },
        %DateTime{} = emitted_at
      ) do
    identity = observation.tracker_identity
    source = get_in(observation.source, [:name])
    percent = get_in(observation.attributes, [:percent])
    expected_topic = if(is_struct(identity, TrackerIdentity), do: "ticket.#{identity.identifier}.agent.#{source}")

    with true <- observation.status == :joinable,
         true <- observation.event_id == id,
         true <- source in @progress_sources,
         true <- topic == expected_topic,
         true <- is_integer(percent) and percent in 0..100,
         %DateTime{} = observed_at <- observation.observed_at,
         {:ok, envelope} <- envelope("aiur.ticket_progress_event", "ticket.progress.changed", id, emitted_at, identity, observation.provenance[:run_id]) do
      {:ok,
       Map.put(envelope, "data", %{
         "percent" => percent,
         "source" => source,
         "observed_at" => DateTime.to_iso8601(observed_at),
         "occurred_at" => iso8601_or_nil(observation.occurred_at)
       })}
    else
      _invalid -> :drop
    end
  end

  def normalize(
        %{
          id: id,
          topic: topic,
          outbound_event: %{kind: :ticket_usage, data: data},
          ticket_observation: %TicketObservation{} = observation
        },
        %DateTime{} = emitted_at
      ) do
    with {:ok, identity, job_id} <- correlation(observation, id),
         true <- topic == "ticket.#{identity.identifier}.usage.changed",
         {:ok, data} <- usage_data(data),
         {:ok, envelope} <- envelope("aiur.ticket_usage_event", "ticket.usage.changed", id, emitted_at, identity, job_id) do
      {:ok, Map.put(envelope, "data", data)}
    else
      _invalid -> :drop
    end
  end

  def normalize(_event, _emitted_at), do: :drop

  defp correlation(
         %TicketObservation{
           status: :joinable,
           event_id: event_id,
           tracker_identity: %TrackerIdentity{} = identity,
           provenance: provenance
         },
         event_id
       ) do
    if TrackerIdentity.joinable?(identity), do: {:ok, identity, provenance[:run_id]}, else: :error
  end

  defp correlation(_observation, _event_id), do: :error

  defp envelope(contract, event_type, id, emitted_at, identity, job_id) do
    if is_integer(id) and id > 0 and TrackerIdentity.joinable?(identity) do
      event = %{
        "contract" => contract,
        "contract_version" => 1,
        "event_id" => "evt_#{id}",
        "event_type" => event_type,
        "emitted_at" => DateTime.to_iso8601(emitted_at),
        "ticket_id" => identity.identifier
      }

      {:ok, maybe_put_job_id(event, job_id)}
    else
      :error
    end
  end

  defp lifecycle_data(%{"lifecycle" => lifecycle, "source" => source, "observed_at" => observed_at})
       when lifecycle in @lifecycles and source in @lifecycle_sources and is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, _datetime, _offset} -> {:ok, %{"lifecycle" => lifecycle, "source" => source, "observed_at" => observed_at}}
      _invalid -> :error
    end
  end

  defp lifecycle_data(_data), do: :error

  defp usage_data(%{"position" => position, "generation" => generation, "delta" => delta})
       when is_integer(position) and position > 0 and is_integer(generation) and generation > 0 do
    with {:ok, delta} <- usage_delta(delta) do
      {:ok, %{"position" => position, "generation" => generation, "delta" => delta}}
    end
  end

  defp usage_data(_data), do: :error

  defp spend_cap_data(
         %{
           "contract" => "aiur.ticket_spend_cap_reached",
           "contract_version" => 1,
           "schema_version" => 1,
           "job_id" => job_id,
           "ticket" => %{"owner" => owner, "repository" => repository, "identifier" => identifier},
           "currency" => "USD",
           "cap_amount" => cap,
           "spent_amount" => spent,
           "remaining_amount" => remaining,
           "state" => "budget_exhausted",
           "end_state" => "budget_exhausted",
           "coverage" => coverage,
           "authority" => authority,
           "configured_at" => configured_at,
           "reached_at" => reached_at
         } = data,
         %TrackerIdentity{} = identity
       ) do
    with true <- job_id == identity.identifier,
         true <- {owner, repository, identifier} == {identity.owner, identity.repository, identity.identifier},
         true <- Enum.all?([cap, spent, remaining], &valid_decimal?/1),
         true <- is_map(coverage) and is_map(authority),
         true <- valid_iso8601?(configured_at) and valid_iso8601?(reached_at) do
      {:ok, Map.take(data, @spend_cap_fields)}
    else
      _invalid -> :error
    end
  end

  defp spend_cap_data(_data, _identity), do: :error

  defp cancel_result_data(
         %{
           "contract" => "aiur.ticket_cancel",
           "contract_version" => 1,
           "issue_identifier" => identifier,
           "tracker_state" => "cancelled",
           "process" => process
         } = data,
         %TrackerIdentity{} = identity
       ) do
    with true <- identifier == identity.identifier,
         :ok <- valid_cancel_process(process) do
      {:ok, Map.take(data, @cancel_fields)}
    else
      _invalid -> :error
    end
  end

  defp cancel_result_data(_data, _identity), do: :error

  defp valid_cancel_process(%{
         "handle" => handle,
         "status" => "exited",
         "exit_status" => exit_status,
         "exited_at" => exited_at,
         "observed_at" => observed_at
       }) do
    if non_empty_string?(handle) and exit_status in @cancel_exit_statuses and valid_iso8601?(exited_at) and
         valid_iso8601?(observed_at),
       do: :ok,
       else: :error
  end

  defp valid_cancel_process(%{
         "handle" => handle,
         "status" => status,
         "exit_status" => nil,
         "exited_at" => nil,
         "observed_at" => observed_at
       })
       when status in ["still_running", "kill_failed", "generation_changed"] do
    if non_empty_string?(handle) and valid_iso8601?(observed_at), do: :ok, else: :error
  end

  defp valid_cancel_process(_process), do: :error

  defp usage_delta(%{
         "tokens" => raw_tokens,
         "cost" => raw_cost,
         "source_version" => source_version,
         "relationship_revision" => relationship_revision,
         "coverage_reasons" => raw_coverage_reasons
       }) do
    with {:ok, tokens} <- tokens(raw_tokens),
         {:ok, cost} <- money(raw_cost),
         true <- non_empty_string?(source_version),
         true <- non_empty_string?(relationship_revision),
         {:ok, coverage_reasons} <- coverage_reasons(raw_coverage_reasons) do
      {:ok,
       %{
         "tokens" => tokens,
         "cost" => cost,
         "source_version" => source_version,
         "relationship_revision" => relationship_revision,
         "coverage_reasons" => coverage_reasons
       }}
    else
      _invalid -> :error
    end
  end

  defp usage_delta(_delta), do: :error

  defp tokens(tokens) when is_map(tokens) do
    if Map.keys(tokens) |> Enum.sort() == Enum.sort(@token_fields) and Enum.all?(@token_fields, &valid_counter?(tokens[&1])) do
      {:ok, Map.take(tokens, @token_fields)}
    else
      :error
    end
  end

  defp tokens(_tokens), do: :error
  defp valid_counter?(nil), do: true
  defp valid_counter?(value), do: is_integer(value) and value >= 0
  defp money(nil), do: {:ok, nil}

  defp money(money) when is_map(money) do
    with true <- Map.keys(money) |> Enum.sort() == Enum.sort(@money_fields),
         true <- Enum.all?(@money_fields, &non_empty_string?(money[&1])),
         true <- Regex.match?(@decimal, money["amount"]),
         true <- money["measurement_kind"] in ["absolute", "delta"],
         true <- money["counter_scope"] in ["request", "turn", "thread", "session"] do
      {:ok, Map.take(money, @money_fields)}
    else
      _invalid -> :error
    end
  end

  defp money(_money), do: :error

  defp valid_decimal?(value), do: is_binary(value) and Regex.match?(@decimal, value)

  defp valid_iso8601?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_iso8601?(_value), do: false

  defp coverage_reasons(reasons) when is_list(reasons) do
    if Enum.all?(reasons, &non_empty_string?/1) and Enum.uniq(reasons) == reasons, do: {:ok, reasons}, else: :error
  end

  defp coverage_reasons(_reasons), do: :error
  defp maybe_put_job_id(event, job_id) when is_binary(job_id) and job_id != "", do: Map.put(event, "job_id", job_id)
  defp maybe_put_job_id(event, _job_id), do: event
  defp non_empty_string?(value), do: is_binary(value) and value != ""
  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(_value), do: nil
end
