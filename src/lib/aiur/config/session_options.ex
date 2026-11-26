defmodule Aiur.Config.SessionOptions do
  @moduledoc false

  @session_options [
    store: :cookie,
    key: "_aiur_key",
    signing_salt: "aiur-session",
    encryption_salt: "aiur-session-encryption",
    same_site: "Lax"
  ]

  @spec runtime_options() :: keyword()
  def runtime_options do
    max_age = Aiur.Config.settings!().dashboard_auth.session_max_age_days * 86_400
    Keyword.put(@session_options, :max_age, max_age)
  end
end
