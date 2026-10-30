defmodule AiurWeb.OperatorControlCenter.AgentLogModal do
  @moduledoc false

  alias Aiur.Conversation.History
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.UnitsPresenter

  @spec find_running_entry(map(), String.t() | TrackerIdentity.t()) :: map() | nil
  def find_running_entry(%{fleet: %{running: running}}, %TrackerIdentity{} = identity) when is_list(running) do
    key = TrackerIdentity.github_key(identity)

    Enum.find(running, fn entry ->
      not is_nil(key) and key == TrackerIdentity.github_key(Map.get(entry, :tracker_identity))
    end)
  end

  def find_running_entry(%{fleet: %{running: running}}, issue_identifier)
      when is_list(running) and is_binary(issue_identifier) do
    Enum.find(running, &(to_string(&1.issue_identifier) == issue_identifier))
  end

  def find_running_entry(_payload, _issue_identifier), do: nil

  @spec build(map() | nil, map() | nil) :: map()
  def build(entry, payload \\ nil)

  def build(nil, _payload) do
    %{
      issue_identifier: "n/a",
      tracker_identity: nil,
      target_key: "unavailable",
      writable_target?: false,
      path: nil,
      messages: [%{role: "system", title: "Session", timestamp: "n/a", body: "No running session found for this issue."}]
    }
  end

  def build(entry, payload) do
    Map.merge(composer(entry, payload), read_agent_log(entry))
  end

  @spec composer(map(), map() | nil) :: map()
  def composer(entry, payload) do
    identity = Map.get(entry, :tracker_identity)

    %{
      issue_identifier: entry.issue_identifier,
      tracker_identity: identity,
      target_key: target_key(identity, entry.issue_identifier),
      writable_target?: unique_running_target?(payload, entry.issue_identifier)
    }
  end

  @spec format_error(term()) :: String.t()
  def format_error(:no_running_agent), do: "Agent is no longer running."
  def format_error(:empty_message), do: "Message is empty."
  def format_error(:message_too_long), do: "Message is too long."
  def format_error(:interrupt_not_supported), do: "Interrupt is not available right now."
  def format_error(:timeout), do: "Send timed out."

  def format_error({:outcome_unknown, _info}),
    do: "Aiur did not answer in time, so the message may still be queued. Check the log, or press Send again to retry without a duplicate."

  def format_error({:not_queued, :timeout}), do: "Send timed out and was not queued."
  def format_error(:unavailable), do: "Orchestrator unavailable."
  def format_error(:ambiguous_identifier), do: "Agent actions require a unique typed target."
  def format_error(:globally_paused), do: "New starts are paused; per-ticket resume is unavailable until new starts resume. You can still pause a running agent for containment."
  def format_error(:max_concurrent_agents_reached), do: "No free agent slot, so the agent stays paused. Try again when a slot frees."
  def format_error(reason), do: inspect(reason)

  defp read_agent_log(%{workspace_path: workspace_path}) when is_binary(workspace_path) do
    History.workspace_log(workspace_path)
  end

  defp read_agent_log(entry) do
    path = agent_log_path(entry)
    %{path: path, messages: path |> History.read_log() |> History.parse_log()}
  end

  defp agent_log_path(%{workspace_path: workspace_path}), do: History.workspace_log_path(workspace_path)
  defp agent_log_path(_entry), do: nil

  defp target_key(%TrackerIdentity{} = identity, issue_identifier) do
    UnitsPresenter.row_token(%{identity: identity}) || to_string(issue_identifier)
  end

  defp target_key(_identity, issue_identifier), do: to_string(issue_identifier)

  @doc """
  True when exactly one running entry carries `identifier`, so a typed or
  dictated message cannot reach the wrong agent. A `nil` payload is the
  composer's not-yet-loaded state and stays writable.
  """
  @spec unique_running_target?(map() | nil, term()) :: boolean()
  def unique_running_target?(nil, _identifier), do: true

  def unique_running_target?(%{fleet: %{running: running}}, identifier) when is_list(running) do
    Enum.count(running, &(to_string(Map.get(&1, :issue_identifier)) == to_string(identifier))) == 1
  end

  def unique_running_target?(_payload, _identifier), do: false
end
