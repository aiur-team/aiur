defmodule Aiur.Tracker.DispatchProvenance do
  @moduledoc "Optional local provenance check, registered by its owning process."

  @spec register((Aiur.Issue.t() -> boolean())) :: :ok
  def register(check) when is_function(check, 1), do: register(:default, check)

  @spec register(atom(), (Aiur.Issue.t() -> boolean())) :: :ok
  def register(key, check) when is_atom(key) and is_function(check, 1) do
    checks = registered() |> Map.put(key, {self(), check})
    Application.put_env(:aiur, :dispatch_provenance, checks)
  end

  @spec authorized?(Aiur.Issue.t()) :: boolean()
  def authorized?(issue) do
    Enum.any?(registered(), fn {_key, {owner, check}} -> Process.alive?(owner) and check.(issue) == true end)
  end

  defp registered do
    case Application.get_env(:aiur, :dispatch_provenance) do
      checks when is_map(checks) -> checks
      {owner, check} when is_pid(owner) and is_function(check, 1) -> %{default: {owner, check}}
      _absent -> %{}
    end
  end

  @spec daemon_account() :: String.t() | nil
  def daemon_account do
    adapter = Aiur.Tracker.adapter()
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :daemon_account, 0), do: adapter.daemon_account(), else: nil
  end
end
