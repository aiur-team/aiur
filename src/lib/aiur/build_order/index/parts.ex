defmodule Aiur.BuildOrder.Index.Parts do
  @moduledoc false
  alias Aiur.BuildOrder.{EpicOverrides, Features, History}
  require Logger
  @keys ~w(history health catch_up features overrides settings repository open queue)a

  @spec read(MapSet.t() | :all, keyword()) :: map()
  def read(dirty, opts) do
    Map.new(Enum.filter(@keys, &(dirty == :all or MapSet.member?(dirty, &1))), fn key -> {key, safe(key, fn -> read_part(key, opts) end)} end)
  end

  @spec safe(atom(), (-> term())) :: term()
  def safe(part, fun) do
    fun.()
  rescue
    error -> failed(part, {error.__struct__, Exception.message(error)})
  catch
    kind, reason -> failed(part, {kind, reason})
  end

  defp failed(part, reason) do
    Logger.warning("build_index part=#{part} read_failed=#{inspect(reason, limit: 20, printable_limit: 200)}")
    {:error, :read_failed}
  end

  defp read_part(:history, opts), do: Keyword.get(opts, :history, History).snapshot(Keyword.get(opts, :history_opts, []))
  defp read_part(:health, opts), do: Keyword.get(opts, :history, History).health(Keyword.get(opts, :history_opts, []))
  defp read_part(:catch_up, opts), do: Keyword.get(opts, :feeder, History.Feeder).catch_up_status(Keyword.get(opts, :feeder_server, History.Feeder))
  defp read_part(:features, opts), do: Keyword.get(opts, :features, Features).snapshot(Keyword.get(opts, :features_opts, []))
  defp read_part(:overrides, opts), do: Keyword.get(opts, :overrides, EpicOverrides).all(Keyword.get(opts, :overrides_opts, []))
  defp read_part(:settings, opts), do: Keyword.get(opts, :settings_fun, &Aiur.Config.settings/0).()
  defp read_part(:repository, opts), do: Keyword.get(opts, :repository_fun, &Aiur.GitHub.Config.configured_repo/0).()
  defp read_part(:open, opts), do: Keyword.get(opts, :open_source, Aiur.OpenTicketSource).snapshot(Keyword.get(opts, :open_server, Aiur.OpenTicketSource))
  defp read_part(:queue, opts), do: Keyword.get(opts, :queue, Aiur.BuildQueue).show()
end
