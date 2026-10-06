defmodule Aiur.Muse.ModelCatalog do
  @moduledoc "Read-only model discovery from Muse's native session host."

  alias Aiur.Muse.Defaults
  alias Aiur.Muse.{Protocol, Transport}

  @spec probe(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def probe(_backend, opts) do
    config = Keyword.get_lazy(opts, :config, fn -> Aiur.Config.backend_config("muse") end)
    command = Map.get(config, "command", Defaults.command()) <> " --no-session-log --disable-shell --disable-write"
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    timeout = Keyword.get(opts, :timeout_ms, 20_000)

    with {:ok, port} <- Transport.start(workspace, command) do
      try do
        with {:ok, result} <- Transport.request(port, Protocol.initialize_frame(1, "1"), timeout),
             {:ok, _} <- Protocol.initialize_result(result),
             :ok <- Transport.send_frame(port, Protocol.initialized_frame()) do
          Transport.request(port, %{"jsonrpc" => "2.0", "id" => 2, "method" => "model/list", "params" => %{}}, timeout)
        end
      after
        Transport.stop(port)
      end
    end
  end

  @spec extract(map()) :: {:ok, [String.t()]} | {:error, term()}
  def extract(%{"models" => models}) when is_list(models) do
    if Enum.all?(models, &valid_model?/1) do
      {:ok, models |> Enum.map(& &1["modelId"]) |> Enum.uniq()}
    else
      {:error, :invalid_muse_model_catalog}
    end
  end

  def extract(_), do: {:error, :invalid_muse_model_catalog}

  defp valid_model?(%{"modelId" => id}) when is_binary(id) and byte_size(id) > 0, do: true
  defp valid_model?(_), do: false
end
