defmodule Aiur.Usage.Headless.Emitter do
  @moduledoc """
  Normal-run emission seam for headless usage envelopes.

  `observe/4` runs unconditionally inside the backend-agnostic per-message
  closure, so emission is daemon-owned and independent of dashboard clients, TUI
  mode, or `--debug`. It drops the provider payload after normalization and
  publishes only validated envelopes; malformed or unattributable events fail
  closed to bounded coverage without crashing the worker or dropping the other
  provider's healthy events.
  """

  require Logger

  alias Aiur.Usage.Headless.{Context, Normalizer}
  alias Aiur.UsageEnvelope

  @publisher_key :usage_headless_publisher

  @spec observe(term(), String.t(), map(), keyword()) :: Normalizer.outcome() | :skip
  def observe(issue, backend, message, opts) when is_binary(backend) and is_map(message) and is_list(opts) do
    with {:ok, context} <- Context.build(issue, backend, opts),
         payload when is_map(payload) <- payload(message) do
      outcome = Normalizer.normalize(payload, raw(message), context, ingested_at(message, opts))
      publish_all(outcome.envelopes, opts)
      outcome
    else
      _skip -> :skip
    end
  rescue
    error ->
      Logger.warning("Headless usage emission failed reason_class=#{inspect_class(error)}")
      :skip
  catch
    :exit, _reason -> :skip
    _kind, _reason -> :skip
  end

  def observe(_issue, _backend, _message, _opts), do: :skip

  defp publish_all(envelopes, opts) do
    publish = publisher(opts)
    Enum.each(envelopes, fn %UsageEnvelope{} = envelope -> safe_publish(publish, envelope) end)
  end

  defp safe_publish(publish, envelope) do
    publish.(envelope)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp publisher(opts) do
    Keyword.get(opts, :usage_publisher) || Application.get_env(:aiur, @publisher_key, &default_publish/1)
  end

  # The DASH-009 ledger is the canonical single writer. Publication is best
  # effort and off the worker's critical path; the ledger owns durability,
  # dedup, and delta derivation.
  defp default_publish(%UsageEnvelope{} = envelope) do
    ledger = Process.whereis(Aiur.UsageLedger)
    tasks = Process.whereis(Aiur.TaskSupervisor)

    cond do
      is_pid(ledger) and is_pid(tasks) ->
        Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> append(envelope) end)
        :ok

      is_pid(ledger) ->
        append(envelope)

      true ->
        :ok
    end
  end

  defp append(envelope) do
    Aiur.UsageLedger.append(envelope)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp payload(message), do: Map.get(message, :payload) || Map.get(message, "payload")
  defp raw(message), do: raw_value(Map.get(message, :raw) || Map.get(message, "raw"))
  defp raw_value(value) when is_binary(value), do: value
  defp raw_value(_value), do: nil

  defp ingested_at(message, opts) do
    case Keyword.get(opts, :ingested_at) || Map.get(message, :timestamp) do
      %DateTime{} = timestamp -> timestamp
      _missing -> DateTime.utc_now()
    end
  end

  defp inspect_class(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp inspect_class(_error), do: "unknown"
end
