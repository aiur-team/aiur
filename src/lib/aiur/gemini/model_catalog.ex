defmodule Aiur.Gemini.ModelCatalog do
  @moduledoc "Read Gemini's model choices from a native ACP session, without a fixed list."

  alias Aiur.Gemini.Session

  def probe(_backend, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    with {:ok, session} <-
           Session.start(workspace,
             config: Keyword.get_lazy(opts, :config, fn -> Aiur.Config.backend_config("gemini") end),
             timeout_ms: Keyword.get(opts, :timeout_ms, 20_000)
           ) do
      try do
        {:ok, %{"models" => %{"availableModels" => session.model_catalog || []}}}
      after
        Session.stop(session)
      end
    end
  end

  def extract(%{"models" => %{"availableModels" => models}}) when is_list(models) do
    if Enum.all?(models, &match?(%{"modelId" => id} when is_binary(id) and id != "", &1)) do
      {:ok, models |> Enum.map(& &1["modelId"]) |> Enum.uniq()}
    else
      {:error, :invalid_gemini_model_catalog}
    end
  end

  def extract(_), do: {:error, :invalid_gemini_model_catalog}
end
