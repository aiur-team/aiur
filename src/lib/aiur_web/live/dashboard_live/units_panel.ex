defmodule AiurWeb.DashboardLive.UnitsPanel do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias AiurWeb.OperatorControlCenter.{UnitsPresenter, UnitsURL}

  @table_sort_columns %{
    "units" => ~w(id unit ticket latest),
    "fleet" => ~w(ticket state waiting latest elapsed commands),
    "tickets" => ~w(id title labels),
    "command-history" => ~w(command decision result),
    "ticket-logs" => ~w(activity detail when),
    "provider-routes" => ~w(route provider api)
  }

  @doc false
  @spec normalize_table_sort(term()) :: String.t() | nil
  def normalize_table_sort(sort) when is_binary(sort) do
    with [table, column, direction] <- String.split(sort, ":"),
         true <- direction in ["asc", "desc"],
         columns when is_list(columns) <- Map.get(@table_sort_columns, table),
         true <- column in columns do
      sort
    else
      _invalid -> nil
    end
  end

  def normalize_table_sort(_sort), do: nil

  @spec assign_units_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_units_view(socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})
    assign(socket, :units_view, UnitsPresenter.project(catalog, UnitsURL.default_selection()))
  end
end
