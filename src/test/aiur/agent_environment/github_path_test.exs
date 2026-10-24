defmodule Aiur.AgentEnvironment.GitHubPathTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEnvironment

  test "governed workspace bin is first in local and remote shell PATH" do
    workspace = "/work/aiur/5911"
    bin = Path.join(workspace, ".aiur-runtime/bin")

    assert {~c"PATH", path} = List.keyfind(AgentEnvironment.workspace_env(workspace), ~c"PATH", 0)
    assert List.first(String.split(List.to_string(path), ":")) == bin

    assert AgentEnvironment.workspace_env_export_prefix(workspace) =~
             "PATH='#{bin}'${PATH:+:$PATH}; export PATH"
  end
end
