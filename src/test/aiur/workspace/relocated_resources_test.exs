defmodule Aiur.Workspace.RelocatedResourcesTest do
  use ExUnit.Case, async: true

  alias Aiur.Init.Templates

  @tag :tmp_dir
  test "copied build reads changed scaffold resources from the workspace", %{tmp_dir: root} do
    resources =
      Templates.__info__(:attributes) |> Keyword.get_values(:external_resource) |> List.flatten()

    resource = Enum.find(resources, &String.ends_with?(&1, "/prompt.md.example"))
    assert Path.type(resource) == :relative
    base = Path.join(root, "base")
    project = Path.join(base, "src")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(project, "lib"))
    resource_path = Path.expand(resource, project)
    File.mkdir_p!(Path.dirname(resource_path))
    File.write!(resource_path, "before")
    options = Keyword.get(Mix.Project.config(), :elixirc_options, [])

    File.write!(Path.join(project, "mix.exs"), """
    defmodule ResourceFixture.MixProject do
      use Mix.Project
      def project, do: [app: :resource_fixture, version: "0.1.0", elixirc_options: #{inspect(options)}]
    end
    """)

    File.write!(Path.join(project, "lib/resource.ex"), """
    defmodule ResourceFixture do
      @external_resource #{inspect(resource)}
      @value File.read!(#{inspect(resource)})
      def value, do: @value
    end
    """)

    env = [{"MIX_ENV", "test"}]

    {output, status} =
      System.cmd("mix", ["compile"], cd: project, env: env, stderr_to_stdout: true)

    assert status == 0, output
    {_, 0} = System.cmd("cp", ["-a", Path.join(base, "."), workspace])
    copied_project = Path.join(workspace, "src")
    File.write!(Path.expand(resource, copied_project), "workspace change")

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", "IO.puts(ResourceFixture.value())"],
        cd: copied_project,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "workspace change"
    assert File.read!(resource_path) == "before"

    for module <- [Templates, Aiur.AgentSkills, AiurWeb.StreamdeckKeyFaceContract],
        [path] <- Keyword.get_values(module.__info__(:attributes), :external_resource) do
      assert Path.type(path) == :relative
      assert File.regular?(path)
    end
  end
end
