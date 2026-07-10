defmodule Aiur.Issue do
  @moduledoc """
  Normalized issue representation used across all tracker backends.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :pr_head_ref,
    :selected_backend,
    paused: false,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          # Set only for PR-anchored work units (opt-in repo-wide PR watch): the
          # human PR's existing head branch the agent works directly. nil for
          # every legacy tracker-issue unit.
          pr_head_ref: String.t() | nil,
          selected_backend: String.t() | nil,
          paused: boolean(),
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
end
