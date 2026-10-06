defmodule Aiur.AgentCompaction.Config do
  @moduledoc """
  Compaction-specific configuration read from the `compaction:` YAML section.

  Config schema:
    compaction:
      enabled: bool (default: false)
      backends: [codex]
      manual_approval: bool (default: false)
      timeout_ms: 30000
  """

  @spec enabled?() :: boolean()
  def enabled? do
    compaction_config = get_compaction_config()
    compaction_config.enabled || false
  end

  @spec backends() :: [String.t()]
  def backends do
    compaction_config = get_compaction_config()
    compaction_config.backends || []
  end

  @spec manual_approval_enabled?() :: boolean()
  def manual_approval_enabled? do
    compaction_config = get_compaction_config()
    compaction_config.manual_approval || false
  end

  @spec should_compact_at_handoff?() :: boolean()
  @spec should_compact_at_handoff?(non_neg_integer() | nil) :: boolean()
  def should_compact_at_handoff?(agent_total_tokens \\ nil) do
    should_compact_at_handoff?(get_compaction_config(), agent_total_tokens)
  end

  @doc false
  def should_compact_at_handoff?(%Aiur.Config.Schema.Compaction{} = config, agent_total_tokens) do
    trigger_requested_at_handoff?(config, agent_total_tokens) and "codex" in config.backends
  end

  def should_compact_at_handoff?(_, _), do: false

  @doc false
  def trigger_requested_at_handoff?(%Aiur.Config.Schema.Compaction{} = config, agent_total_tokens) do
    auto_trigger = config.auto_trigger || %Aiur.Config.Schema.Compaction.AutoTrigger{}
    manual? = config.manual_approval
    automatic? = auto_trigger.enabled and is_integer(agent_total_tokens) and agent_total_tokens >= auto_trigger.token_threshold
    config.enabled and (manual? or automatic?)
  end

  def trigger_requested_at_handoff?(_, _), do: false

  def settings, do: get_compaction_config()

  @spec timeout_ms() :: non_neg_integer()
  def timeout_ms do
    compaction_config = get_compaction_config()

    case compaction_config.timeout_ms do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> 30_000
    end
  end

  defp get_compaction_config do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.compaction || %Aiur.Config.Schema.Compaction{}
      {:error, _} -> %Aiur.Config.Schema.Compaction{}
    end
  end
end
