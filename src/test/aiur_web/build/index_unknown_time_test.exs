defmodule AiurWeb.Build.IndexUnknownTimeTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index

  test "a snapshot whose member join time is :unknown serves the board with an unknown spark" do
    r = row(7, %{labels: ["complexity:2"]})
    feature = %{slug: "pag", label: "Pagination", hue: 175, epics: [%{key: "f-pag", label: "Page"}], from: r.created_at, to: :none, baseline: :none}
    owners = %{7 => %{feature: "pag", epic: "f-pag", joined_at: :unknown}}
    p = put_in(parts([r]), [:features], {:ok, %{features: %{"pag" => feature}, owners: owners, also: %{}, health: health()}})

    pid =
      start_supervised!(
        {Index,
         name: nil,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> p end,
         timer: fn _, _, _ -> make_ref() end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         clock: &now/0}
      )

    assert {:ok, snapshot} = Index.window(pid, "Etc/UTC")
    stats = snapshot.features["pag"].stats
    assert stats["spark"] == nil
    assert stats["total"] == 1
  end
end
