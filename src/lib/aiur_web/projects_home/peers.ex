defmodule AiurWeb.ProjectsHome.Peers do
  @moduledoc """
  Peer gateways the browser should ask for a summary, read from `~/.aiur/remote-instances.yaml`.

  An entry with no `url` (inbound-only) is left out. A URL that is not `https` is kept but marked
  `off_tailnet`, so the page links to it instead of fetching it. An unreadable registry is no peers.
  """

  @type peer :: %{name: String.t(), gateway_id: String.t() | nil, label: String.t(), url: String.t(), off_tailnet: boolean()}

  @spec list(Path.t()) :: [peer()]
  def list(path \\ default_path()) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"instances" => instances}} when is_map(instances) -> instances |> Enum.flat_map(&peer/1) |> Enum.sort_by(& &1.name)
      _ -> []
    end
  rescue
    _ -> []
  end

  @spec default_path() :: Path.t()
  def default_path, do: Application.get_env(:aiur, :projects_home_registry) || Path.join(System.user_home!(), ".aiur/remote-instances.yaml")

  defp peer({name, %{"url" => url} = entry}) when is_binary(url) and url != "" do
    [
      %{
        name: to_string(name),
        gateway_id: string_or_nil(entry["gateway_id"]),
        label: string_or_nil(entry["label"]) || to_string(name),
        url: String.trim_trailing(url, "/"),
        off_tailnet: not String.starts_with?(url, "https://")
      }
    ]
  end

  defp peer(_), do: []

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil
end
