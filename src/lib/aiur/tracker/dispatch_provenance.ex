defmodule Aiur.Tracker.DispatchProvenance do
  @moduledoc "Optional local provenance check, registered by its owning process."

  @spec register((Aiur.Issue.t() -> boolean())) :: :ok
  def register(check) when is_function(check, 1) do
    Application.put_env(:aiur, :dispatch_provenance, {self(), check})
  end

  @spec authorized?(Aiur.Issue.t()) :: boolean()
  def authorized?(issue) do
    case Application.get_env(:aiur, :dispatch_provenance) do
      {owner, check} when is_pid(owner) and is_function(check, 1) -> Process.alive?(owner) and check.(issue) == true
      _absent -> false
    end
  end

  @spec daemon_account() :: String.t() | nil
  def daemon_account do
    adapter = Aiur.Tracker.adapter()
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :daemon_account, 0), do: adapter.daemon_account(), else: nil
  end
end
