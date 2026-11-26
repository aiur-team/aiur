defmodule Aiur.Project.SingletonInventoryTest do
  use ExUnit.Case, async: true

  @adr Enum.map(["MPG-301.md", "MPG-301-inventory.md"], &Path.expand("../../../../docs/research/" <> &1, __DIR__))
  @lib Path.expand("../../../lib", __DIR__)
  @row ~r/^\|\s*(?:\d+\s*\|\s*)?`([A-Za-z0-9_.]+)`\s*\|\s*(per-project|machine)\s*\|.*\|\s*([^|]+?)\s*\|$/
  @registering ~r/name: __MODULE__|:name, __MODULE__|Project\.via\(__MODULE__\)/
  # Rows whose process is not started with a literal `name: __MODULE__` (its supervisor child
  # spec or a caller names it), so the scan cannot see them.
  @unscanned ["Aiur.PubSub", "Aiur.TaskSupervisor", "Aiur.Orchestrator", "Aiur.Events.Exchange", "Aiur.Events.SubscriptionStoreSupervisor"]

  # Module => {owner, ticket}, parsed from the ADR so the test cannot drift from a copy of it.
  defp adr do
    rows =
      for line <- Stream.flat_map(@adr, &File.stream!/1),
          [_, mod, owner, ticket] <- [Regex.run(@row, String.trim_trailing(line))],
          do: {mod, {owner, ticket}}

    assert rows != [], "parsed no rows from #{inspect(@adr)}"
    Map.new(rows)
  end

  # Module => source for every lib module that registers a process under its own name.
  defp scanned do
    for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
        src = read_source!(file),
        Regex.match?(@registering, src),
        [_, mod] <- [Regex.run(~r/^\s*defmodule ([A-Za-z0-9_.]+) do/m, src)],
        into: %{},
        do: {mod, src}
  end

  test "every module registering under its own name is classified by the ADR" do
    assert Map.keys(scanned()) -- Map.keys(adr()) == []
  end

  test "the ADR lists no module that no longer registers under its own name" do
    assert (Map.keys(adr()) -- Map.keys(scanned())) -- @unscanned == []
  end

  test "every per-project module owned by MPG-303..305 resolves its own name through Aiur.Project" do
    scanned = scanned()

    offenders =
      for {mod, {"per-project", ticket}} <- adr(),
          ticket =~ ~r/^MPG-30[345]/,
          src = scanned[mod],
          not Regex.match?(~r/Aiur\.Project\.(?:via|name|whereis)\(/, src),
          do: mod

    assert offenders == []
  end

  # `File.read!/1` queues on the VM-wide file server, which async source scans
  # saturate in CI; `:prim_file` reads in the calling process instead.
  defp read_source!(path) do
    {:ok, source} = :prim_file.read_file(path)
    source
  end
end
