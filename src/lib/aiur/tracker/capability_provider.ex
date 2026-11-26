defmodule Aiur.Tracker.CapabilityProvider do
  @moduledoc "Read-only configured tracker and repository identity."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ~w(tracker.github tracker.linear)

  @impl true
  def capabilities(context) do
    Map.new(["github", "linear"], fn kind ->
      entry =
        case context.settings do
          %{tracker: %{kind: ^kind}} -> %{state: :available}
          :unavailable -> %{state: :unknown, reason: :unknown}
          _ -> %{state: :unavailable, reason: :not_configured}
        end

      {"tracker." <> kind, entry}
    end)
  end

  @impl true
  def sections(context), do: repository(context)

  @spec repository(Provider.context(), keyword()) :: map()
  def repository(context, opts \\ []) do
    identity = Keyword.get(opts, :identity_fun, &Aiur.Tracker.project_identity/0).()
    %{repository: describe(context.settings, identity)}
  rescue
    _error -> %{repository: nil}
  catch
    :exit, _reason -> %{repository: nil}
  end

  defp describe(%{tracker: %{kind: "github"}}, identity) when is_binary(identity) do
    case String.split(identity, "/") do
      [owner, name] when owner != "" and name != "" -> %{kind: "github", owner: owner, name: name}
      _ -> nil
    end
  end

  defp describe(%{tracker: %{kind: kind}}, identity) when kind in ["linear", "memory"] and is_binary(identity),
    do: %{kind: kind, owner: nil, name: identity}

  defp describe(_settings, _identity), do: nil
end
