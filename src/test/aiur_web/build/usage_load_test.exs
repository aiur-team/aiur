defmodule AiurWeb.Build.UsageLoadTest do
  use Aiur.TestSupport
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias AiurWeb.Build.Usage

  defmodule MeterSource do
    def load(pid, _opts) do
      send(pid, :loaded)
      %{codex: I.snapshot(:codex, %{"primary" => I.window(42)})}
    end

    def reload(pid, message, _opts) do
      send(pid, {:reloaded, message})
      load(pid, [])
    end
  end

  defmodule FailedSource do
    def load(_context, _opts), do: raise("meter down")
  end

  setup do
    dir = Aiur.TestSupport.tmp_root!("usage-ledger")
    File.mkdir_p!(dir)
    path = Path.join(dir, "model-usage.json")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: path}
  end

  defp opts(path), do: [meter_source: MeterSource, durable_path: path, accounts_fun: fn -> %{} end, github_server: :absent_usage_github, elevenlabs_server: :absent_usage_elevenlabs]

  test "U11 credential filter follows registry provider credentials", %{path: path} do
    before = System.get_env("DEEPSEEK_API_KEY")
    on_exit(fn -> if before, do: System.put_env("DEEPSEEK_API_KEY", before), else: System.delete_env("DEEPSEEK_API_KEY") end)
    System.delete_env("DEEPSEEK_API_KEY")
    refute :deepseek in Usage.load(self(), opts(path)).families
    System.put_env("DEEPSEEK_API_KEY", "test-only")
    assert :deepseek in Usage.load(self(), opts(path)).families
  end

  test "U6 U15 durable read uses explicit path and failure isolates other sources", %{path: path} do
    write = fn limit -> File.write!(path, Jason.encode!(%{backends: %{codex: %{hourly: %{used: 100, limit: limit}, observed_at: DateTime.to_iso8601(I.now())}}})) end
    write.(100)
    assert Usage.load(self(), opts(path)).durable.codex == %{percent: 100, observed_at: I.now()}
    write.(0)
    inputs = Usage.load(self(), opts(path))
    assert inputs.durable == %{}
    assert inputs.meters.codex.windows["primary"].used_percent == 42
    assert inputs.github == {:error, :unavailable}
    assert inputs.accounts == %{}
  end

  test "reload forwards facade update and locked read performs no I/O", %{path: path} do
    message = {AiurWeb.FinancialData, :updated, :identity}
    inputs = Usage.load(self(), Keyword.put(opts(path), :reload, message))
    assert inputs.meters.codex.provider == :codex
    assert_received {:reloaded, ^message}
    assert_received :loaded
    Usage.read(:locked, opts(path))
    assert Usage.subscribe(:locked) == :ok
    refute_received :loaded
    refute_received {:reloaded, _}
  end

  test "one failed source leaves account and quota values intact", %{path: path} do
    quota = I.quota()
    server = spawn_link(fn -> quota_server(quota) end)
    on_exit(fn -> if Process.alive?(server), do: Process.exit(server, :normal) end)
    read_opts = opts(path) |> Keyword.put(:meter_source, FailedSource) |> Keyword.put(:github_server, server) |> Keyword.put(:accounts_fun, fn -> %{"work" => I.account(1, 96)} end)
    inputs = Usage.load(self(), read_opts)
    assert inputs.meters == %{}
    assert inputs.github == {:ok, quota}
    assert inputs.accounts["work"].reading.windows |> hd() |> Map.fetch!(:used_percent) == 1
  end

  defp quota_server(quota) do
    receive do
      {:"$gen_call", from, :snapshot} ->
        GenServer.reply(from, quota)
        quota_server(quota)
    end
  end
end
