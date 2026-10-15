defmodule AiurWeb.Routes.Experiments do
  @moduledoc "Experiment page routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro pages do
    quote do
      scope "/" do
        pipe_through([:dashboard_auth, :dashboard_pages, :browser])

        live_session :experiments, on_mount: [AiurWeb.DashboardPagesGate, AiurWeb.FinancialDataAccess] do
          live("/experiments", AiurWeb.ExperimentsLive, :experiments)
          live("/experiments/:id", AiurWeb.ExperimentsLive, :experiment)
        end
      end
    end
  end
end
