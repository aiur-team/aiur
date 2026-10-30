defmodule AiurWeb.VoiceConverse.Join do
  @moduledoc false
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.VoiceConverse.Host.Worker
  alias AiurWeb.{EndpointConfig, VoiceJoinPayload, VoiceTargets}

  @spec parse(term()) :: {:ok, map()} | {:error, map()}
  def parse(%{"mode" => "converse", "surface" => "conversation_panel"} = payload) do
    case VoiceJoinPayload.parse(Map.put(payload, "mode", "dictate")) do
      {:ok, %{target: %{kind: kind}} = parsed} when kind in [:worker, :executor] -> {:ok, parsed}
      _ -> error(:invalid_payload)
    end
  end

  def parse(_), do: error(:invalid_payload)

  @spec validate(map()) :: :ok | {:error, map()}
  def validate(%{kind: :worker} = target), do: VoiceTargets.validate(target, "agent_composer")
  def validate(%{kind: :executor} = target), do: VoiceTargets.validate(target, "executor_composer")

  @spec available() :: :ok | {:error, map()}
  def available do
    report = (EndpointConfig.get(:capabilities_report_fun) || (&Aiur.Capabilities.report/0)).()

    case get_in(report, [:capabilities, "voice.conversation"]) do
      %{state: state} when state in [:available, :degraded, "available", "degraded"] -> :ok
      %{reason: reason} -> error(reason)
      _ -> error(:unknown)
    end
  rescue
    _ -> error(:unknown)
  catch
    :exit, _ -> error(:unknown)
  end

  @spec target(map()) :: {:ok, :executor | Worker.t()} | {:error, map()}
  def target(%{kind: :executor}), do: {:ok, :executor}

  def target(%{kind: :worker, ticket: ticket}) do
    snapshot = (EndpointConfig.get(:voice_converse_snapshot_fun) || fn -> StatusReport.snapshot_api(Aiur.Orchestrator, 2_000) end).()

    case snapshot do
      %{running: rows} -> worker(Enum.filter(rows, &(&1[:identifier] == ticket)))
      _ -> error(:unknown)
    end
  rescue
    _ -> error(:unknown)
  catch
    :exit, _ -> error(:unknown)
  end

  defp worker([%{tracker_identity: %Aiur.TrackerIdentity{} = identity} = row]), do: {:ok, %Worker{identity: identity, live_source: row[:live_source]}}
  defp worker(_), do: error(:target_not_writable)

  @spec error(term()) :: {:error, map()}
  def error(reason) do
    code = to_string_code(reason)
    {:error, %{reason_code: code, reason: "Voice conversation could not proceed (#{code})."}}
  end

  defp to_string_code(reason) when is_atom(reason) or is_binary(reason) do
    code = to_string(reason)
    if code in AiurWeb.VoiceReasonCode.codes(), do: code, else: "unknown"
  end

  defp to_string_code(_), do: "unknown"
end
