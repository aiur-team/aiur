defmodule Aiur.AgentCompaction.Config do
  @moduledoc """
  Compaction-specific configuration read from the `compaction:` YAML section.

  Config schema:
    compaction:
      enabled: bool (default: false)
      backends:
        - codex
      manual_approval: bool (default: false)
      auto_trigger:
        enabled: bool (default: false)
        token_threshold: 50000
        message_count_threshold: 20
        elapsed_time_minutes: 60
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

  @spec auto_trigger_enabled?() :: boolean()
  def auto_trigger_enabled? do
    compaction_config = get_compaction_config()

    case compaction_config.auto_trigger do
      %{enabled: enabled} -> enabled || false
      nil -> false
    end
  end

  @spec token_threshold() :: non_neg_integer()
  def token_threshold do
    compaction_config = get_compaction_config()

    case compaction_config.auto_trigger do
      %{token_threshold: threshold} when is_integer(threshold) and threshold >= 1000 -> threshold
      _ -> 50_000
    end
  end

  @spec message_count_threshold() :: non_neg_integer()
  def message_count_threshold do
    compaction_config = get_compaction_config()

    case compaction_config.auto_trigger do
      %{message_count_threshold: threshold} when is_integer(threshold) and threshold >= 1 -> threshold
      _ -> 20
    end
  end

  @spec elapsed_time_minutes() :: non_neg_integer()
  def elapsed_time_minutes do
    compaction_config = get_compaction_config()

    case compaction_config.auto_trigger do
      %{elapsed_time_minutes: minutes} when is_integer(minutes) and minutes >= 1 -> minutes
      _ -> 60
    end
  end

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
