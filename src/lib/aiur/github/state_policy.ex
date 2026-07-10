defmodule Aiur.GitHub.StatePolicy do
  @moduledoc """
  Label-encoded GitHub issue state policy.
  """

  @spec normalize_state(String.t()) :: String.t()
  def normalize_state(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "-")
  end

  @spec human_review_target_state?(String.t()) :: boolean()
  def human_review_target_state?(state_name), do: normalize_state(state_name) == "human-review"

  @spec active_target_state?(String.t()) :: boolean()
  def active_target_state?(state_name) do
    not terminal_state_name?(state_name)
  end

  @spec terminal_state_label?(String.t(), String.t()) :: boolean()
  def terminal_state_label?(label, prefix) do
    label
    |> String.replace_prefix("#{prefix}:", "")
    |> terminal_state_name?()
  end

  @spec terminal_state_name?(String.t()) :: boolean()
  def terminal_state_name?(state_name) do
    normalize_state(state_name) in ["done", "cancelled", "canceled"]
  end

  @spec state_label(String.t(), String.t()) :: String.t()
  def state_label(prefix, state_name), do: "#{prefix}:#{normalize_state(state_name)}"
end
