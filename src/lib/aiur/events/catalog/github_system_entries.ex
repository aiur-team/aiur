defmodule Aiur.Events.Catalog.GithubSystemEntries do
  @moduledoc false

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog.Entry

  @alerts [
    # aiur/main_watch.ex
    {"system.*.ci.flake_rerun", "github-listeners"},
    # aiur/github/listeners/firehose/window.ex
    {"system.firehose.event_truncation", "github-listeners"},
    # aiur/github/listeners/firehose/window.ex
    {"system.firehose.event_truncation.resolved", "github-listeners"},
    # aiur/github/quota/shell_observations.ex
    {"system.github.budget.broker_reconcile_stale", "github-access"},
    # aiur/github/broker_timeout.ex
    {"system.github.budget_broker_degraded", "github-access"},
    # aiur/github/broker_timeout.ex
    {"system.github.budget_broker_degraded.resolved", "github-access"},
    # aiur/github/broker_timeout.ex
    {"system.github.budget_broker_retry", "github-access"},
    # aiur/github/credential_headroom.ex
    {"system.github.budget_meter_disagreement", "github-access"},
    # aiur/github/quota/windows.ex
    {"system.github.quota.*.*", "github-access"},
    # aiur/github/quota/windows.ex
    {"system.github.quota.*.secondary", "github-access"},
    # aiur/github/hold_sweep.ex
    {"system.github.quota.implausible_hold", "github-access"},
    # aiur/github/quota.ex
    {"system.github.quota.sample_stale", "github-access"},
    # aiur/github/quota.ex
    {"system.github.quota.sample_stale.resolved", "github-access"},
    # aiur/github/resource_store/memory.ex
    {"system.github.resource_store.cap", "github-access"},
    # aiur/github/app_token_refresher.ex
    {"system.github_app_token.identity_mismatch", "github-access"},
    # aiur/github/app_token_refresher.ex
    {"system.github_app_token.permission_violation", "github-access"},
    # aiur/github/app_token_refresher.ex
    {"system.github_app_token.refresh_failed", "github-access"},
    # aiur/github/app_token_refresher.ex
    {"system.github_app_token.refresh_recovered", "github-access"},
    # aiur_web/github_webhook/auth.ex
    {"system.github_webhook.secret_missing", "github-listeners"},
    # aiur/main_watch.ex
    {"system.main.ci.canary", "github-listeners"},
    # aiur/main_watch.ex
    {"system.main.ci.failed", "github-listeners"},
    # aiur/main_watch.ex
    {"system.main.ci.flake_rerun", "github-listeners"},
    # aiur/main_watch.ex
    {"system.main.ci.flaked", "github-listeners"},
    # aiur/main_watch.ex
    {"system.main.ci.unavailable", "github-listeners"},
    # aiur/main_watch/fixer.ex
    {"system.main.fixer.dispatch_unavailable", "github-listeners"},
    # aiur/main_watch/fixer.ex
    {"system.main.fixer.failed", "github-listeners"},
    # aiur/main_watch/fixer.ex
    {"system.main.fixer.held", "github-listeners"},
    # aiur/main_watch/fixer.ex
    {"system.main.fixer.needs_triage", "github-listeners"},
    # aiur/main_watch/fixer.ex
    {"system.main.fixer.no_pr", "github-listeners"},
    # aiur/main_watch/fixer_watchdog.ex
    {"system.main.fixer.stalled", "github-listeners"}
  ]

  @entries Enum.map(@alerts, fn {pattern, owner} -> Entry.alert(pattern, owner, export?: true) end)

  @spec entries() :: [Entry.t()]
  def entries, do: @entries
end
