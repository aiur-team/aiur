defmodule Aiur.Executor.TranscriptFormat do
  @moduledoc """
  Claude disk transcript census and drift diagnostics, without record content.

  Tested versions: 2.1.287 through 2.1.299, pinned to the synthetic 2.1.29x
  fixtures. Refresh the fixtures and this range together. Classification describes
  supported record kinds, not whether an individual record yields visible text.
  Counters and the alert latch belong to the binding generation, across files.
  """
  @ignored ~w(queue-operation system pr-link mode permission-mode atis-latch ai-title last-prompt agent-name bridge-session file-history-delta file-history-snapshot)
  @attachments ~w(total_tokens_reminder queued_command hook_non_blocking_error edited_text_file task_reminder deferred_tools_record environment skill_listing)
  @tested_versions ~r/\A2\.1\.(28[7-9]|29\d)\z/

  @spec classify(term()) :: :mapped | :ignored_known | :unknown
  def classify(%{"type" => type}) when type in ["assistant", "user"], do: :mapped
  def classify(%{"type" => type}) when type in @ignored, do: :ignored_known
  def classify(%{"type" => "attachment", "attachment" => %{"type" => "queued_command", "commandMode" => "prompt", "prompt" => prompt}}) when is_binary(prompt) and prompt != "", do: :mapped
  def classify(%{"type" => "attachment", "attachment" => %{"type" => type}}) when type in @attachments, do: :ignored_known
  def classify(_), do: :unknown

  @spec version_status(term()) :: :tested | :untested | :absent
  def version_status(%{"version" => version}) when is_binary(version), do: if(Regex.match?(@tested_versions, version), do: :tested, else: :untested)
  def version_status(%{"version" => version}) when not is_nil(version), do: :untested
  def version_status(_), do: :absent

  @spec new() :: map()
  def new,
    do: %{
      "total" => 0,
      "types" => %{"mapped" => 0, "ignored_known" => 0, "unknown" => 0},
      "versions" => %{"tested" => 0, "untested" => 0, "absent" => 0},
      "untested_version" => nil,
      "alerted" => false
    }

  @spec count(map(), term()) :: map()
  def count(counts, record) do
    status = version_status(record)
    counts = counts |> Map.update!("total", &(&1 + 1)) |> update_in(["types", Atom.to_string(classify(record))], &(&1 + 1))
    counts = update_in(counts, ["versions", Atom.to_string(status)], &(&1 + 1))
    if status == :untested, do: Map.put(counts, "untested_version", safe_version(record)), else: counts
  end

  @spec alert(map(), map(), (String.t(), keyword() -> term())) :: map()
  def alert(counts, binding, emit) do
    drift? = counts["types"]["unknown"] * 100 > counts["total"] * 2 or counts["versions"]["untested"] > 0

    if counts["total"] >= 200 and drift? and not counts["alerted"] do
      payload = %{binding_id: binding.binding_id, generation: binding.generation, counts: counts}
      message = "Executor transcript format changed or is untested; conversation entries may be missing. Counts: #{Jason.encode!(counts)}"

      case emit.("system.executor.transcript.drift", message: message, needs_attention: true, exchange_payload: payload) do
        :ok -> Map.put(counts, "alerted", true)
        _ -> counts
      end
    else
      counts
    end
  end

  defp safe_version(%{"version" => version}) when is_binary(version) do
    if Regex.match?(~r/\A\d{1,5}\.\d{1,5}\.\d{1,5}\z/, version), do: version, else: "invalid"
  end

  defp safe_version(_), do: "invalid"
end
