defmodule Aiur.BrowserHarness.ProjectsHomeRegistry do
  @moduledoc "Points the projects home at two fake peers (`nook.test`, `lab.test`) that specs intercept with `page.route`."

  @registry """
  version: 1
  instances:
    nook:
      url: https://nook.test
      gateway_id: NOOK
      label: Nook
    lab:
      url: https://lab.test
      gateway_id: LAB
      label: Lab
  """

  @spec put!() :: :ok
  def put! do
    path = Path.join(System.tmp_dir!(), "projects-home-registry-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, @registry)
    Application.put_env(:aiur, :projects_home_registry, path)
  end
end
