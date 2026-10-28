defmodule Aiur.GitHub.BudgetBrokerSource do
  @moduledoc "Embeds ordered broker fragments for build-time assembly."

  @root Path.expand("../../../priv", __DIR__)
  @paths Enum.map(~w(00_schema 10_admission 20_report_and_cli), &Path.join([@root, "github_budget", &1 <> ".py"]))
  for path <- @paths, do: @external_resource(path)
  @source Enum.map_join(@paths, &File.read!/1)

  @spec text() :: String.t()
  def text, do: @source

  @spec install!(Path.t()) :: Path.t()
  def install!(priv_dir) do
    File.mkdir_p!(priv_dir)
    path = Path.join(priv_dir, "github_budget.py")
    install_file!(path, @source)
    path
  end

  defp install_file!(path, contents) do
    if File.read(path) != {:ok, contents} do
      :ok = Aiur.Fs.atomic_write(path, contents, mode: 0o755)
    end
  end
end
