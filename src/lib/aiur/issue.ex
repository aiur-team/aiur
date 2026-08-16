defmodule Aiur.Issue do
  @moduledoc """
  Normalized issue representation used across all tracker backends.
  """

  alias Aiur.TrackerIdentity

  defstruct [
    :id,
    :identifier,
    :tracker_identity,
    :title,
    :description,
    :priority,
    :state,
    :state_labels,
    :branch_name,
    :url,
    :assignee_id,
    :pr_head_ref,
    :selected_backend,
    :selected_model,
    :creator_login,
    :dispatch_revision,
    paused: false,
    # GitHub ingestion resolves this before an issue can reach dispatch. Other
    # tracker backends retain the safe compatibility default.
    dispatch_authorized?: true,
    # Explicit operator-held marker (`agent:parked`): dispatch ignores the
    # ticket and comment-driven rework is refused, even when an `agent:*` state
    # label is present. `false` for every tracker backend that lacks the marker.
    parked: false,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          tracker_identity: TrackerIdentity.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          state_labels: [String.t()] | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          # Set only for PR-anchored work units (opt-in repo-wide PR watch): the
          # human PR's existing head branch the agent works directly. nil for
          # every legacy tracker-issue unit.
          pr_head_ref: String.t() | nil,
          selected_backend: String.t() | nil,
          # The model half of the selected route. `selected_backend` alone
          # cannot express `openrouter:anthropic/claude-sonnet-5`, so a
          # dispatch that picked a route would have shown as bare `openrouter`
          # and re-resolved some other model at session start.
          selected_model: String.t() | nil,
          creator_login: String.t() | nil,
          dispatch_revision: String.t() | nil,
          paused: boolean(),
          dispatch_authorized?: boolean(),
          parked: boolean(),
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec paused?(t()) :: boolean()
  def paused?(%__MODULE__{paused: paused}), do: paused == true
  def paused?(_issue), do: false

  @doc "Returns whether the issue carries the explicit `agent:parked` operator-held marker."
  @spec parked?(t()) :: boolean()
  def parked?(%__MODULE__{parked: parked}), do: parked == true
  def parked?(_issue), do: false

  @doc "Returns whether a tracker target names the issue by raw id or canonical identifier."
  @spec identifier_matches?(term(), term(), term()) :: boolean()
  def identifier_matches?(id, identifier, target) do
    id = to_string(id || "")
    identifier = to_string(identifier || "")
    target = to_string(target || "")

    target != "" and
      (target == id or target == identifier or String.ends_with?(identifier, "##{target}"))
  end

  @doc """
  Returns the issue's explicitly joinable or nonjoinable identity. Legacy and
  compatibility records remain absent (`nil`) and must not be used as joins.
  """
  @spec tracker_identity(t() | map() | term()) :: TrackerIdentity.t() | nil
  def tracker_identity(%__MODULE__{tracker_identity: identity}), do: identity
  def tracker_identity(%{tracker_identity: identity}), do: identity
  def tracker_identity(_issue), do: nil
end
