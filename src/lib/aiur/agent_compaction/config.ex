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
  """

  @behaviour Aiur.AgentConfig

  # Default thresholds (locked after analysis)
  @default_token_threshold 50_000
  @default_message_count_threshold 20
  @default_elapsed_time_minutes 60

  @spec enabled?() :: boolean()
  def enabled? do
    case section_value("enabled") do
      true -> true
      _ -> false
    end
  end

  @spec backends() :: [String.t()]
  def backends do
    case section_value("backends") do
      list when is_list(list) ->
        Enum.filter(list, &is_binary/1)
      _ ->
        []
    end
  end

  @spec manual_approval_enabled?() :: boolean()
  def manual_approval_enabled? do
    case section_value("manual_approval") do
      true -> true
      _ -> false
    end
  end

  @spec auto_trigger_enabled?() :: boolean()
  def auto_trigger_enabled? do
    auto = section_value("auto_trigger") || %{}
    case auto["enabled"] do
      true -> true
      _ -> false
    end
  end

  @spec token_threshold() :: non_neg_integer()
  def token_threshold do
    auto = section_value("auto_trigger") || %{}
    case auto["token_threshold"] do
      value when is_integer(value) and value >= 1000 -> value
      _ -> @default_token_threshold
    end
  end

  @spec message_count_threshold() :: non_neg_integer()
  def message_count_threshold do
    auto = section_value("auto_trigger") || %{}
    case auto["message_count_threshold"] do
      value when is_integer(value) and value >= 1 -> value
      _ -> @default_message_count_threshold
    end
  end

  @spec elapsed_time_minutes() :: non_neg_integer()
  def elapsed_time_minutes do
    auto = section_value("auto_trigger") || %{}
    case auto["elapsed_time_minutes"] do
      value when is_integer(value) and value >= 1 -> value
      _ -> @default_elapsed_time_minutes
    end
  end

  @spec validate!() :: :ok | {:error, String.t()}
  def validate! do
    with :ok <- validate_enabled(),
         :ok <- validate_backends(),
         :ok <- validate_thresholds() do
      :ok
    end
  end

  defp validate_enabled do
    case enabled?() do
      true -> :ok
      false ->
        # Compaction disabled is valid; no error
        :ok
    end
  end

  defp validate_backends do
    backends = backends()
    cond do
      Enum.empty?(backends) and enabled?() ->
        {:error, "compaction.backends must not be empty when compaction is enabled"}
      Enum.any?(backends, &(&1 not in ["codex", "claude"])) ->
        {:error, "compaction.backends contains unrecognized backend; only 'codex' and 'claude' are valid"}
      true ->
        :ok
    end
  end

  defp validate_thresholds do
    cond do
      token_threshold() < 1000 ->
        {:error, "compaction.auto_trigger.token_threshold must be >= 1000"}
      message_count_threshold() < 1 ->
        {:error, "compaction.auto_trigger.message_count_threshold must be >= 1"}
      elapsed_time_minutes() < 1 ->
        {:error, "compaction.auto_trigger.elapsed_time_minutes must be >= 1"}
      true ->
        :ok
    end
  end

  defp section_value(key) do
    Aiur.Config.section("compaction", key)
  end
end
