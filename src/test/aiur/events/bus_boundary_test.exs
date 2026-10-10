defmodule Aiur.Events.BusBoundaryTest do
  # Temporary ratchet until C4-T03 moves these rules into
  # scripts/check-components.py (MP-R1-C1). Deliberately green on main.
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib/aiur", __DIR__)

  @members ~w(exchange topic publisher id_generator subscription_store
              subscription_store_supervisor universal_subscriptions
              agent_subscription_policy debug_log)
           |> Enum.map(&"events/#{&1}.ex")
           |> Kernel.++(["ticket_observation.ex"])

  # Bus modules that are not scanned members, plus kernel/config. Deliberately
  # not the whole `Aiur.Events` namespace: Sanitizer, BranchRefStore and
  # CommentFilter belong to github-listeners (CR-R2-1(b)).
  @allowed_modules ~w(Aiur.Events Aiur.Events.SubscriptionStoreRegistry
                      Aiur.Config Aiur.JsonStore)

  # {member_file, referenced_module} => ticket that removes the edge.
  # Seam tickets delete their rows; that deletion is the proof the edge is gone.
  @ratchet %{
    {"events/publisher.ex", "Aiur.GitHub.AgentMarker"} => "C2-T06",
    {"events/publisher.ex", "Aiur.GitHub.Config"} => "C2-T06",
    {"events/publisher.ex", "Aiur.GitHub.ResourceStore"} => "C2-T06",
    {"events/publisher.ex", "Aiur.Webhooks"} => "C2-T06",
    {"events/publisher.ex", "Aiur.IssueLog"} => "C2-T03",
    {"events/id_generator.ex", "Aiur.Executor.StatePaths"} => "C2-T07",
    {"events/id_generator.ex", "Aiur.LaunchStateAdoption"} => "C2-T07",
    {"events/subscription_store.ex", "Aiur.Orchestrator"} => "C2-T01",
    {"events/subscription_store.ex", "Aiur.Alerts"} => "C2-T01",
    {"events/subscription_store.ex", "Aiur.IssueLog"} => "C2-T03",
    {"events/debug_log.ex", "Phoenix.PubSub"} => "C2-T05",
    {"events/debug_log.ex", "Aiur.PubSub"} => "C2-T05",
    # Unassigned: tracker types in the L1 spine; MP-R1 decides (CONTRACT-REQUESTS).
    {"ticket_observation.ex", "Aiur.TrackerIdentity"} => "unassigned",
    {"ticket_observation.ex", "Aiur.OpaqueIdentifier"} => "unassigned"
  }

  defp strip(source) do
    source
    |> String.replace(~r/@(?:moduledoc|doc)\s+(?:~[sS])?"""\n.*?"""/s, "")
    |> String.replace(~r/@(?:moduledoc|doc)\s+(?:~[sS])?"[^\n]*"/, "")
    |> String.replace(~r/#(?!\{).*$/m, "")
  end

  # Expands `alias Aiur.{A, B}` into fully qualified names, then scans every
  # fully qualified Aiur.* / Phoenix.PubSub reference (alias lines included).
  # Only the alias line's own module is recorded: `alias Aiur.GitHub` then
  # `GitHub.Config` records `Aiur.GitHub`, not `Aiur.GitHub.Config`.
  defp references(source) do
    code = strip(source)

    expanded =
      ~r/\b((?:Aiur|Phoenix)(?:\.[A-Z]\w*)*)\.\{([^}]*)\}/
      |> Regex.scan(code)
      |> Enum.flat_map(fn [_, prefix, names] ->
        names |> String.split(",", trim: true) |> Enum.map(&"#{prefix}.#{String.trim(&1)}")
      end)

    scanned =
      ~r/\b(?:Aiur(?:\.[A-Z]\w*)+|Phoenix\.PubSub)/
      |> Regex.scan(code)
      |> List.flatten()

    (expanded ++ scanned) |> Enum.uniq() |> Enum.sort()
  end

  defp member_modules do
    for file <- @members do
      "Aiur." <> (file |> String.trim_trailing(".ex") |> Path.split() |> Enum.map_join(".", &Macro.camelize/1))
    end
  end

  defp allowed?(mod) do
    mod in @allowed_modules or mod in member_modules() or
      Enum.any?(~w(Aiur.Config Aiur.JsonStore), &String.starts_with?(mod, &1 <> "."))
  end

  defp edges do
    for file <- @members,
        mod <- @lib |> Path.join(file) |> File.read!() |> references(),
        not allowed?(mod),
        do: {file, mod}
  end

  test "event-bus members reference only kernel, config, members, or recorded ratchet edges" do
    unrecorded =
      for {file, mod} = edge <- edges(), not is_map_key(@ratchet, edge) do
        "#{file} -> #{mod}"
      end

    assert unrecorded == []
  end

  test "every recorded ratchet edge still exists (remove the entry when the seam lands)" do
    current = MapSet.new(edges())

    stale =
      for {{file, mod} = edge, ticket} <- @ratchet, not MapSet.member?(current, edge) do
        "#{file} -> #{mod} (remove entry; landed in #{ticket})"
      end

    assert stale == []
  end
end
