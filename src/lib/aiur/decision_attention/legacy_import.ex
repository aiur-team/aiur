defmodule Aiur.DecisionAttention.LegacyImport do
  @moduledoc false

  require Logger

  @default_import_limit 100

  @spec load((-> term())) :: list()
  def load(loader) do
    case loader.() do
      attentions when is_list(attentions) ->
        attentions

      _other ->
        Logger.warning("decision_attention legacy_import_failed reason=invalid_loader_result")
        []
    end
  rescue
    error ->
      Logger.warning("decision_attention legacy_import_failed reason=#{inspect(Exception.message(error))}")
      []
  catch
    kind, reason ->
      Logger.warning("decision_attention legacy_import_failed reason=#{inspect({kind, reason})}")
      []
  end

  @spec messages(list(), pos_integer()) :: [tuple() | :legacy_attention_import_complete]
  def messages(attentions, limit) do
    {to_import, ignored} = Enum.split(attentions, limit)

    if ignored != [] do
      Logger.warning(
        "decision_attention legacy_import_truncated " <>
          "limit=#{limit} ignored_count=#{length(ignored)}"
      )
    end

    Enum.map(to_import, &{:restore_attention, &1}) ++ [:legacy_attention_import_complete]
  end

  @spec limit(keyword()) :: pos_integer()
  def limit(opts) do
    case Keyword.get(opts, :import_limit, @default_import_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_import_limit
    end
  end
end
