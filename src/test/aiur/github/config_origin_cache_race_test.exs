defmodule Aiur.GitHub.ConfigOriginCacheRaceTest do
  # async: false — the origin-repo cache is a VM-global persistent term.
  use ExUnit.Case, async: false

  alias Aiur.GitHub.Config

  @origin_cache_key {Config, :resolved_origin_repo}

  # #4071: a resolver that read the cache as unset shells out to `git` for
  # milliseconds; a value cached during that window must survive its return.
  test "a resolve that was in flight keeps the value cached meanwhile" do
    previous = :persistent_term.get(@origin_cache_key, :unset)

    on_exit(fn ->
      if previous == :unset, do: :persistent_term.erase(@origin_cache_key), else: :persistent_term.put(@origin_cache_key, previous)
    end)

    :persistent_term.put(@origin_cache_key, "acme/widgets")

    assert Config.resolve_origin_repo(fn -> "real/checkout" end) == "acme/widgets"
    assert :persistent_term.get(@origin_cache_key) == "acme/widgets"
  end
end
