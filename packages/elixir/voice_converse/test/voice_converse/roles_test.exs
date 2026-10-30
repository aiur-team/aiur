defmodule VoiceConverse.RolesTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.{Config, Roles}

  setup do
    dir = Path.join(System.tmp_dir!(), "roles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "operator files override inline defaults by id and warn", %{dir: dir} do
    File.write!(
      Path.join(dir, "worker.md"),
      "---\nid: worker\ntitle: Operator\ntargets: [worker]\n---\nOperator prompt\n"
    )

    config = %Config{roles: [%{id: "worker", title: "Default", prompt: "Default prompt"}], roles_dir: dir}
    assert {:ok, role} = Roles.get(config, "worker")
    assert role.prompt == "Operator prompt"
    assert Roles.list(config) == [%{id: "worker", title: "Operator", targets: ["worker"]}]
    assert [%{reason: :duplicate_id, id: "worker"}] = Roles.load(config).warnings
  end

  test "hash covers exactly the prompt and glossary" do
    config = %Config{roles: [%{id: "worker", title: "Ticket", prompt: "Discuss"}], glossary: ["Terms", "More"]}
    assert {:ok, role} = Roles.get(config, "worker")
    assert role.prompt == "Discuss\n\nTerms\n\nMore"
    assert role.hash == Base.encode16(:crypto.hash(:sha256, role.prompt), case: :lower)
    assert {:ok, changed} = Roles.get(%{config | glossary: ["Changed"]}, "worker")
    refute role.hash == changed.hash

    assert {:ok, changed} =
             Roles.get(%{config | roles: [%{id: "worker", title: "Ticket", prompt: "Changed"}]}, "worker")

    refute role.hash == changed.hash
    assert {:error, :not_found} = Roles.get(config, "unknown")
  end

  test "invalid front matter and metadata are skipped with warnings", %{dir: dir} do
    for {name, text} <- [
          {"bad.md", "---\nid: [broken\n---\nBody"},
          {"absent.md", "No metadata"},
          {"invalid.md", "---\nid: worker\ntitle: Invalid\ntargets: [bogus]\n---\nBody"},
          {"empty.md", "---\nid: worker\ntitle: Empty\ntargets: [worker]\n---\n"}
        ],
        do: File.write!(Path.join(dir, name), text)

    File.write!(Path.join(dir, "_glossary.md"), "Ignored")
    assert %{roles: [], warnings: warnings} = Roles.load(%Config{roles_dir: dir})
    assert Enum.sort(Enum.map(warnings, &Path.basename(&1.source))) == ["absent.md", "bad.md", "empty.md", "invalid.md"]
    assert Enum.all?(warnings, &(&1.reason in [:invalid_role, :invalid_front_matter]))
  end

  test "missing directories retain inline roles and other read failures warn", %{dir: dir} do
    config = %Config{roles_dir: Path.join(dir, "missing"), roles: [%{id: "x", title: "X", prompt: "X"}]}
    assert %{roles: [%{id: "x"}], warnings: []} = Roles.load(config)
    file = Path.join(dir, "file")
    File.write!(file, "not a directory")
    assert [%{source: ^file, reason: :enotdir}] = Roles.load(%{config | roles_dir: file}).warnings
    assert [%{reason: :invalid_role}] = Roles.load(%Config{roles: [nil]}).warnings
  end
end
