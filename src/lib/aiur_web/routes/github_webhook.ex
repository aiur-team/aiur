defmodule AiurWeb.Routes.GithubWebhook do
  @moduledoc "Component routes expanded inside AiurWeb.Router."
  use AiurWeb.Kit, :routes

  defmacro receiver do
    quote do
      # Keep the webhook receiver ahead of every other scope: the dashboard's
      # trailing `/*path` catch-all would otherwise claim this path and answer with
      # a Basic-Auth challenge instead of a signature check. The literal path is
      # asserted against `AiurWeb.GithubWebhook.path/0` in the router tests, since
      # the endpoint's body reader keys raw-body caching off that same value.
      scope "/" do
        pipe_through(:github_webhook)

        # `log: false` suppresses Phoenix's default dispatch log, which would
        # otherwise write the entire decoded webhook payload into the debug log.
        post("/api/v1/github/webhook", AiurWeb.GithubWebhookController, :create, log: false)
      end
    end
  end
end
