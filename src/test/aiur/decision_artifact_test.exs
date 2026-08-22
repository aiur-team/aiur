defmodule Aiur.DecisionArtifactTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionArtifact

  setup do
    original = Application.get_env(:aiur, :decision_artifact_allowed_hosts)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:aiur, :decision_artifact_allowed_hosts)
        value -> Application.put_env(:aiur, :decision_artifact_allowed_hosts, value)
      end
    end)

    root = Path.join(System.tmp_dir!(), "aiur-decision-artifact-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  describe "local paths" do
    test "an absolute path canonicalizing under a safe root passes", %{root: root} do
      file = Path.join(root, "notes.md")
      File.write!(file, "hello")

      assert {:ok, %{kind: :path, value: canonical}} = DecisionArtifact.validate(file, [root])
      assert canonical == Path.expand(file)
    end

    test "a non-existent path under a safe root still passes (no file needed yet)", %{root: root} do
      file = Path.join(root, "missing.md")
      assert {:ok, %{kind: :path}} = DecisionArtifact.validate(file, [root])
    end

    test "a relative path is rejected", %{root: root} do
      assert DecisionArtifact.validate("relative/path.md", [root]) ==
               {:error, :artifact_path_not_absolute}
    end

    test "a path outside every safe root is rejected", %{root: root} do
      outside = Path.join(System.tmp_dir!(), "outside-#{System.pid()}-#{System.unique_integer([:positive])}.md")
      assert DecisionArtifact.validate(outside, [root]) == {:error, :artifact_path_outside_root}
    end

    test "a traversal sequence that escapes the root is rejected", %{root: root} do
      escaped = Path.join(root, "../escaped.md")
      assert DecisionArtifact.validate(escaped, [root]) == {:error, :artifact_path_outside_root}
    end

    test "a symlink that resolves outside every safe root is rejected", %{root: root} do
      outside_dir =
        Path.join(System.tmp_dir!(), "aiur-artifact-outside-#{System.pid()}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      target = Path.join(outside_dir, "secret.md")
      File.write!(target, "secret")

      link = Path.join(root, "escape_link")
      File.ln_s!(target, link)

      assert DecisionArtifact.validate(link, [root]) == {:error, :artifact_path_outside_root}
    end
  end

  describe "remote URLs" do
    test "an allowlisted HTTPS host passes" do
      assert {:ok, %{kind: :url, value: "https://github.com/its-everdred/aiur"}} =
               DecisionArtifact.validate("https://github.com/its-everdred/aiur", [])
    end

    test "a dot-delimited subdomain of an allowlisted host passes" do
      Application.put_env(:aiur, :decision_artifact_allowed_hosts, ["example.com"])

      assert {:ok, %{kind: :url}} =
               DecisionArtifact.validate("https://sub.example.com/path", [])
    end

    test "a deceptive host suffix without a dot boundary is rejected" do
      Application.put_env(:aiur, :decision_artifact_allowed_hosts, ["github.com"])

      assert DecisionArtifact.validate("https://evilgithub.com/x", []) ==
               {:error, :artifact_url_host_not_allowed}
    end

    test "an insecure http:// scheme is rejected" do
      assert DecisionArtifact.validate("http://github.com/x", []) ==
               {:error, :artifact_url_insecure_scheme}
    end

    test "a URL with embedded credentials is rejected" do
      assert DecisionArtifact.validate("https://user:pass@github.com/x", []) ==
               {:error, :artifact_url_has_credentials}
    end

    test "a credential in an allowlisted URL path or query is redacted" do
      secret = "GHSAT0" <> String.duplicate("A", 36)
      url = "https://raw.githubusercontent.com/org/repo/main/file?token=#{secret}"

      assert {:ok, %{kind: :url, value: redacted}} = DecisionArtifact.validate(url, [])
      refute redacted =~ secret
      assert redacted =~ "[REDACTED:ghsat]"
    end

    test "a percent-encoded credential in an allowlisted URL is rejected" do
      secret = "GHSAT0" <> String.duplicate("A", 36)
      encoded_secret = String.replace_prefix(secret, "G", "%47")
      url = "https://raw.githubusercontent.com/org/repo/main/file?token=#{encoded_secret}"

      assert DecisionArtifact.validate(url, []) ==
               {:error, :artifact_url_has_credentials}
    end

    test "a non-allowlisted host is rejected" do
      assert DecisionArtifact.validate("https://example.com/x", []) ==
               {:error, :artifact_url_host_not_allowed}
    end

    test "a local-host URL is rejected via the same allowlist" do
      assert DecisionArtifact.validate("https://localhost/x", []) ==
               {:error, :artifact_url_host_not_allowed}
    end
  end

  test "an empty or scheme-less garbage value is rejected" do
    assert DecisionArtifact.validate("", []) == {:error, :artifact_invalid}
    assert DecisionArtifact.validate("ftp://example.com/x", []) == {:error, :artifact_invalid}
  end
end
