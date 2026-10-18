defmodule AiurWeb.DocsFixtureSmokeTest do
  # Boots the documentation dashboard fixture the way the screenshot capture
  # does — a separate `mix run --no-start` VM — because it registers global
  # names (`Aiur.PubSub`, `AiurWeb.Endpoint`) that the test VM already owns.
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000
  @fixture "test/manual/executor_control_center_docs_fixture.exs"

  test "the docs fixture boots and renders the dashboard root" do
    port = free_port()
    tmp = Path.join(System.tmp_dir!(), "aiur-docs-fixture-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)

    fixture =
      Port.open({:spawn_executable, System.find_executable("mix")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["run", "--no-start", @fixture],
        cd: File.cwd!(),
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"AIUR_DOCS_TMP", String.to_charlist(tmp)},
          {~c"AIUR_DOCS_PORT", ~c"#{port}"}
        ]
      ])

    {:os_pid, os_pid} = Port.info(fixture, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true) end)

    body = await_root(fixture, "http://127.0.0.1:#{port}/", System.monotonic_time(:millisecond) + 150_000, "")

    assert body =~ "Aiur"
    assert body =~ "example-org"
  end

  defp await_root(fixture, url, deadline, output) do
    receive do
      {^fixture, {:data, chunk}} ->
        await_root(fixture, url, deadline, output <> chunk)

      {^fixture, {:exit_status, status}} ->
        flunk("docs fixture exited with #{status} before serving /:\n#{String.slice(output, -4_000, 4_000)}")
    after
      500 ->
        case Req.get(url, auth: {:basic, "example:example"}, retry: false, receive_timeout: 10_000) do
          {:ok, %{status: 200, body: body}} ->
            body

          _not_ready ->
            if System.monotonic_time(:millisecond) > deadline,
              do: flunk("docs fixture never served /:\n#{String.slice(output, -4_000, 4_000)}"),
              else: await_root(fixture, url, deadline, output)
        end
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
