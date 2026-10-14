defmodule Aiur.CLISubcommandsTest do
  use ExUnit.Case, async: true

  alias Aiur.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defp deps do
    %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      set_server_host_override: fn _host -> :ok end,
      ensure_all_started: fn -> {:ok, [:aiur]} end
    }
  end

  test "parses the findings command and its filters without starting the app" do
    assert {:findings, %{unfiled: true, slugs: true, scope: "aiur"}} =
             CLI.evaluate(["findings", "--unfiled", "--slugs", "--scope", "aiur"], deps())

    assert {:error, usage} = CLI.evaluate(["findings", "--scope", "host"], deps())
    assert usage =~ "aiur findings"
  end

  test "parses validated findings writes and digest generation" do
    record = Jason.encode!(%{"slug" => "dispatch-pressure"})

    assert {:findings, %{record: ^record, repo: "aiur-team/aiur"}} =
             CLI.evaluate(["findings", "--record", record, "--repo", "aiur-team/aiur"], deps())

    assert {:findings, %{digest: true, scope: "aiur"}} =
             CLI.evaluate(["findings", "--digest", "--scope", "aiur"], deps())

    assert {:error, _usage} = CLI.evaluate(["findings", "--record", record], deps())
    assert {:error, _usage} = CLI.evaluate(["findings", "--digest", "--unfiled"], deps())
  end

  test "parses ask creation, resolution, and JSON reads without starting the app" do
    assert {:asks, {:create, %{title: "Enable CI readiness", body: "gh auth refresh -s workflow", urgency: "high", blocking: true}}} =
             CLI.evaluate(["ask", "Enable CI readiness", "--body", "gh auth refresh -s workflow", "--urgency", "high", "--blocking"], deps())

    assert {:asks, {:done, %{id: "ask_abc", note: "operator completed it"}}} =
             CLI.evaluate(["ask", "--done", "ask_abc", "--note", "operator completed it"], deps())

    assert {:asks, {:list, %{status: :all, json: true}}} = CLI.evaluate(["asks", "--all", "--json"], deps())
    assert {:error, _usage} = CLI.evaluate(["ask", "title", "--body", "x", "--body-file", "body.txt"], deps())
    assert {:error, _usage} = CLI.evaluate(["asks", "--open", "--all"], deps())
  end

  test "loads ask body files without changing command blocks" do
    path = Aiur.TestSupport.tmp_root!("aiur-ask-body")
    body = "gh auth refresh -h github.com -s workflow\ngh auth token\n"
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)

    assert {:asks, {:create, %{body: ^body}}} = CLI.evaluate(["ask", "Enable CI readiness", "--body-file", path], deps())
  end

  test "routes a bare init subcommand to the wizard with force false" do
    assert {:init, %{force: false}} = CLI.evaluate(["init"], deps())
  end

  test "routes init --force to the wizard with force true" do
    assert {:init, %{force: true}} = CLI.evaluate(["init", "--force"], deps())
  end

  test "rejects init with extra positional arguments" do
    assert {:error, message} = CLI.evaluate(["init", "extra"], deps())
    assert message =~ "Usage: aiur"
  end

  test "does not treat a non-init positional as a subcommand" do
    parent = self()

    deps =
      Map.merge(deps(), %{
        file_regular?: fn path ->
          send(parent, {:workflow_checked, path})
          true
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "some/config.yaml"], deps)
    assert_received {:workflow_checked, _path}
  end

  test "routes variadic todo IDs and only without starting the workflow" do
    assert {:todo, ["11", "12", "13"], %{only: true}} =
             CLI.evaluate(["--todo", "11", "12,13", "--only"], deps())
  end

  test "deduplicates todo IDs in first-seen order" do
    assert {:todo, ["11", "12"], %{only: false}} =
             CLI.evaluate(["--todo", "11", "12", "11"], deps())
  end

  test "canonicalizes leading-zero todo IDs to match enumerated identifiers" do
    assert {:todo, ["11"], %{only: false}} =
             CLI.evaluate(["--todo", "011"], deps())
  end

  test "dedupes a leading-zero ID against its canonical form" do
    assert {:todo, ["11"], %{only: false}} =
             CLI.evaluate(["--todo", "011", "11"], deps())
  end

  test "rejects todo without IDs" do
    assert {:error, message} = CLI.evaluate(["--todo"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "rejects invalid todo IDs" do
    assert {:error, message} = CLI.evaluate(["--todo", "11", "not-an-id"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "rejects only without todo" do
    assert {:error, message} = CLI.evaluate(["--only"], deps())
    assert message =~ "aiur --todo <id>"
  end

  test "rejects run flags combined with todo" do
    assert {:error, message} = CLI.evaluate(["--todo", "11", "--host", "127.0.0.1"], deps())
    assert message =~ "aiur --todo <id>"
  end
end
