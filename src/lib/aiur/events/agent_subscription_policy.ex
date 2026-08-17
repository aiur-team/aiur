defmodule Aiur.Events.AgentSubscriptionPolicy do
  @moduledoc """
  Authorization policy for topic patterns created explicitly by ticket agents.

  Automatic and Executor subscriptions do not pass through this policy. An
  agent-created binding must name one literal ticket so a single binding cannot
  observe the Executor control plane or the whole fleet.
  """

  @spec validate(term()) :: :ok | {:error, :agent_subscription_scope_forbidden}
  def validate(pattern) when is_binary(pattern) do
    if syntactically_valid?(pattern) do
      case String.split(pattern, ".") do
        ["ticket", identifier, _segment | _rest] when identifier not in ["*", "#"] ->
          :ok

        _other ->
          {:error, :agent_subscription_scope_forbidden}
      end
    else
      {:error, :agent_subscription_scope_forbidden}
    end
  end

  def validate(_pattern), do: {:error, :agent_subscription_scope_forbidden}

  defp syntactically_valid?(pattern) do
    pattern != "" and pattern == String.trim(pattern) and
      not String.starts_with?(pattern, ".") and not String.ends_with?(pattern, ".") and
      not String.contains?(pattern, "..")
  end
end
