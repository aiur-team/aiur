defmodule VoiceConverse.SessionRolesTest do
  use ExUnit.Case, async: true
  alias VoiceConverse.{Config, Roles, TranscriptStore}
  alias VoiceConverse.Session.{Runtime, Start}
  alias VoiceConverse.Testing.{FakeBriefingSource, FakeProvider, StaticCredentials}

  setup do
    root = Path.join(System.tmp_dir!(), "session-roles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> VoiceConverse.TestCleanup.rm_rf!(root) end)

    {:ok, config} =
      Config.new(
        transcript_root: root,
        credentials: StaticCredentials,
        briefing_source: FakeBriefingSource,
        provider: {FakeProvider, [open_observer: self()]},
        llm: "test-model",
        cloud_disclosure_accepted: true,
        roles_dir: root,
        roles: [%{id: "worker", title: "Ticket", prompt: "Discuss"}],
        glossary: ["Terms"]
      )

    %{config: config, root: root}
  end

  test "session records and sends one prompt snapshot even if role files change", %{config: config, root: root} do
    id = "vc_aaaaaaaaaaaaaaaaaaaaaa"
    assert {:ok, expected} = Roles.get(config, "worker")
    assert {:ok, state} = Start.state(config, %{id: "1", kind: :worker}, id, [])
    assert {:ok, [started | _], _meta} = TranscriptStore.read(root, id)
    assert started["role_id"] == "worker"
    assert started["role_hash"] == expected.hash

    File.write!(Path.join(root, "worker.md"), "---\nid: worker\ntitle: New\ntargets: [worker]\n---\nChanged")
    Runtime.open(self(), state, :initial)
    assert_receive {:fake_provider, :open_spec, spec}
    assert spec.system_prompt == "Discuss\n\nTerms"
    assert_receive {:provider_opened, :initial, {:ok, ref}}
    FakeProvider.close(ref)
    Runtime.open(self(), %{state | reconnects: 1}, :reconnect)
    assert_receive {:fake_provider, :open_spec, retry_spec}
    assert retry_spec.system_prompt == spec.system_prompt
    assert_receive {:provider_opened, :reconnect, {:ok, retry_ref}}
    FakeProvider.close(retry_ref)
    TranscriptStore.close(state.store)
  end

  test "unknown explicit roles and incompatible targets refuse before creating a transcript", %{
    config: config,
    root: root
  } do
    assert {:error, :role_not_found} =
             Start.state(config, %{kind: :worker}, "vc_bbbbbbbbbbbbbbbbbbbbbb", role_id: "missing")

    assert {:error, :role_target_mismatch} =
             Start.state(
               %{config | roles: [%{id: "worker", title: "Ticket", prompt: "Discuss", targets: ["worker"]}]},
               %{kind: :executor},
               "vc_cccccccccccccccccccccc",
               role_id: "worker"
             )

    assert File.ls!(root) == []
  end

  test "role configuration rejects invalid container types", %{config: config} do
    for {field, value} <- [roles: "wrong", roles_dir: 42, glossary: [42]] do
      assert {:error, %{field: ^field, reason: :invalid}} = Config.validate(Map.put(config, field, value))
    end
  end
end
