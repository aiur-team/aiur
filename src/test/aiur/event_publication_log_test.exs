defmodule Aiur.EventPublicationLogTest do
  use ExUnit.Case, async: false

  alias Aiur.EventPublicationLog

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-publication-log-#{System.unique_integer([:positive])}")
    publication_file = Path.join(root, "trusted/log/event-publications.ndjson")

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{publication_file: publication_file, root: root}
  end

  test "workspace symlinks cannot redirect the daemon-owned append", %{
    publication_file: publication_file,
    root: root
  } do
    workspace = Path.join(root, "workspace")
    redirected = Path.join(root, "redirected")
    File.mkdir_p!(workspace)
    File.mkdir_p!(redirected)
    File.ln_s!(redirected, Path.join(workspace, "logs"))

    assert :ok =
             EventPublicationLog.write(
               workspace,
               %{event: "event_publication_completed"},
               path: publication_file
             )

    assert File.exists?(publication_file)
    refute File.exists?(Path.join(redirected, "event-publications.ndjson"))
  end

  test "a symlinked configured outcome file is rejected", %{
    publication_file: publication_file,
    root: root
  } do
    target = Path.join(root, "outside.ndjson")
    File.mkdir_p!(Path.dirname(publication_file))
    File.write!(target, "preserve\n")
    File.ln_s!(target, publication_file)

    assert {:error, {:symlink_rejected, ^publication_file}} =
             EventPublicationLog.write(
               nil,
               %{event: "event_publication_completed"},
               path: publication_file
             )

    assert File.read!(target) == "preserve\n"
  end
end
