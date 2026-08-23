defmodule Aiur.Workspace.BootstrapImageTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.BootstrapImage

  setup do
    test_root = Aiur.TestSupport.tmp_root!("bi_test")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "maybe_seed/3 with no bootstrap_image configured returns :ok", %{workspace: workspace} do
    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = BootstrapImage.maybe_seed(workspace, issue_context, nil)
  end

  test "bootstrap_image_copy_script/0 contains exit 66 and all four cache paths" do
    script = BootstrapImage.bootstrap_image_copy_script()

    assert script =~ "exit 66"
    assert script =~ "src/deps"
    assert script =~ "src/_build"
    assert script =~ "deps"
    assert script =~ "_build"
  end

  test "bootstrap_image_copy_script/0 starts with set -eu and contains a for-loop over cache paths" do
    script = BootstrapImage.bootstrap_image_copy_script()

    assert String.starts_with?(script, "set -eu\n")
    assert script =~ "for path in"
    assert script =~ "found=0"
  end

  test "bootstrap_image_script/3 includes docker pull when pull? true, omits it when false" do
    workspace = "/tmp/test-workspace"
    image = "test-image:latest"

    with_pull = BootstrapImage.bootstrap_image_script(workspace, image, true)
    without_pull = BootstrapImage.bootstrap_image_script(workspace, image, false)

    assert with_pull =~ "docker pull"
    refute without_pull =~ "docker pull"

    assert with_pull =~ "docker run --rm --user"
    assert without_pull =~ "docker run --rm --user"
  end
end
