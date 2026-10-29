defmodule AiurWeb.InstanceRosterData do
  @moduledoc false

  alias Aiur.Instance.Roster

  @spec read() :: {:ok, map()} | {:error, term()} | :disabled
  def read do
    case Application.get_env(:aiur, :instance_roster_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Roster.list()
    end
  rescue
    _error -> {:error, :store_unavailable}
  end
end
