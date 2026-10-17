defmodule Aiur.RunTelemetry.DaemonEvents do
  @moduledoc "Sanitized daemon metric event routing and capacity binding."

  alias Aiur.Protocol.MapAccess

  @spec metadata_fields() :: [atom()]
  def metadata_fields, do: ~w(from_state to_state blocker head_sha input_tokens output_tokens cached_tokens cost_amount cost_currency coverage)a

  @spec patterns() :: [String.t()]
  def patterns do
    ~w(ticket.*.pr.opened ticket.*.pr.merged ticket.*.pr.ready_for_review ticket.*.ci.passed ticket.*.ci.failed ticket.*.issue.commented ticket.*.pr.review_comment)
  end

  @spec topic(term()) :: {:ok, String.t(), String.t()} | :error
  def topic(topic) when is_binary(topic) do
    case Regex.run(
           ~r/^ticket\.([^.]+)\.(pr\.opened|pr\.merged|pr\.ready_for_review|ci\.passed|ci\.failed|issue\.commented|pr\.review_comment)$/,
           topic
         ) do
      [_all, ticket, kind] -> {:ok, ticket, kind}
      _other -> :error
    end
  end

  def topic(_topic), do: :error

  @spec event(String.t()) :: String.t()
  def event("pr.opened"), do: "pr_opened"
  def event("pr.merged"), do: "pr_merged"
  def event("pr.ready_for_review"), do: "pr_ready"
  def event("ci." <> _outcome), do: "ci_result"
  def event(_comment), do: "comment_received"

  @spec ci_metadata(String.t(), map()) :: map()
  # CI results publish their PR number and head SHA at the top level of the event.
  def ci_metadata("ci." <> outcome, event) do
    %{outcome: outcome, head_sha: short_sha(value(event, :head_sha)), pr_number: value(event, :pr_number)}
  end

  def ci_metadata(_kind, _event), do: %{}

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short_sha(_sha), do: nil

  @spec admission_signal(term()) :: String.t() | nil
  def admission_signal(%{signal: signal}) when is_atom(signal), do: Atom.to_string(signal)
  def admission_signal(_hold), do: nil

  defp value(map, key), do: MapAccess.get(map, key)
end
