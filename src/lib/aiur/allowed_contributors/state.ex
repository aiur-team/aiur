defmodule Aiur.AllowedContributors.State do
  @moduledoc """
  The allowed-contributor intake server's state, shared by `Intake` (the
  decision) and `Refresh` (the allow-list read) so a misspelled key fails at
  compile time rather than as a runtime `KeyError` inside the trust boundary.

  Every external effect is an injected function, so tests drive the whole
  server against a fake GitHub, a capturing publisher, and a controllable
  wall clock (`clock_fun`, milliseconds — the rate window is persisted, so it
  must survive a restart, which a monotonic clock does not).
  """

  alias Aiur.AllowedContributors.{Ledger, Source}
  alias Aiur.Events.Publisher
  alias Aiur.Executor.StatePaths
  alias Aiur.GitHub.{Config, Transport}

  @refresh_ms 600_000
  @rate_limit 5

  @enforce_keys [:owner, :repo, :ledger_path, :audit_path, :ledger]
  defstruct [
    :owner,
    :repo,
    :ledger_path,
    :audit_path,
    :ledger,
    :token_fun,
    :config_fun,
    :request_fun,
    :publish_fun,
    :alert_fun,
    :clock_fun,
    :aiur_logins_fun,
    snapshot: nil,
    membership: %{},
    rate_limit: @rate_limit,
    refresh_ms: @refresh_ms,
    last_on_demand_refresh: nil
  ]

  @type t :: %__MODULE__{
          owner: String.t(),
          repo: String.t(),
          ledger_path: Path.t(),
          audit_path: Path.t(),
          ledger: Ledger.t(),
          snapshot: nil | :absent | Source.snapshot(),
          membership: map(),
          rate_limit: pos_integer(),
          refresh_ms: pos_integer() | :infinity,
          last_on_demand_refresh: integer() | nil,
          config_fun: (-> map() | nil),
          token_fun: (-> String.t() | nil),
          request_fun: (map() -> term()),
          publish_fun: (String.t(), map(), keyword() -> term()),
          alert_fun: (String.t(), String.t(), keyword() -> term()),
          clock_fun: (-> integer()),
          aiur_logins_fun: (-> [String.t()])
        }

  @spec new(keyword(), String.t(), String.t()) :: t()
  def new(opts, owner, repo) do
    dir = Keyword.get_lazy(opts, :state_dir, &StatePaths.dir/0)
    ledger_path = Path.join(dir, "#{repo}.allowed-contributors.json")

    %__MODULE__{
      owner: owner,
      repo: repo,
      ledger_path: ledger_path,
      audit_path: Path.join(dir, "#{repo}.allowed-contributors.audit.ndjson"),
      ledger: Ledger.load(ledger_path),
      rate_limit: Keyword.get(opts, :rate_limit, @rate_limit),
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      config_fun: Keyword.get(opts, :config_fun, &allowed_contributors/0),
      token_fun: Keyword.get(opts, :token_fun, &Config.token/0),
      request_fun: Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
      publish_fun: Keyword.get(opts, :publish_fun, &Publisher.publish/3),
      alert_fun: Keyword.get(opts, :alert_fun, &Aiur.Alerts.emit_custom/3),
      clock_fun: Keyword.get(opts, :clock_fun, fn -> System.os_time(:millisecond) end),
      aiur_logins_fun: Keyword.get(opts, :aiur_logins_fun, &aiur_logins/0)
    }
  end

  defp allowed_contributors, do: Aiur.Config.settings!().tracker.github.allowed_contributors

  defp aiur_logins do
    [Config.bot_account(), Config.daemon_account()]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  rescue
    _error -> []
  end
end
