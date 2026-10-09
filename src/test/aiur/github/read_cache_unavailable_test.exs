defmodule Aiur.GitHub.ReadCacheUnavailableTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.ReadCache

  test "reports an unavailable cache without restarting shared application children" do
    owner = Process.whereis(ReadCache)
    entries = :ets.whereis(:aiur_github_read_cache_entries)
    assert is_pid(owner)
    assert entries != :undefined

    # A separate VM owns these tables: even a failed assertion cannot take down the suite's rest_for_one tree.
    script = """
    alias Aiur.GitHub.ReadCache
    {:ok, owner} = ReadCache.start_link(sweep_interval_ms: 0)
    %{available?: true, entries: 0} = ReadCache.snapshot()
    :ok = GenServer.stop(owner)
    %{available?: false, entries: nil, markers: nil, hit_rate: nil, totals: %{hit: 0}} = ReadCache.snapshot()
    IO.puts("unavailable cache observed")
    """

    # app_dir works under coverage too, when :code.which/1 returns :cover_compiled.
    ebin = Application.app_dir(:aiur, "ebin")
    {output, status} = System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2", "-pa", ebin, "-e", script], stderr_to_stdout: true)

    assert Process.whereis(ReadCache) == owner
    assert :ets.whereis(:aiur_github_read_cache_entries) == entries
    assert ReadCache.snapshot().available?
    assert status == 0, output
    assert output =~ "unavailable cache observed"
  end
end
