defmodule Aiur.RetryEngineFixture do
  @moduledoc false

  alias Aiur.TrackerIdentity

  def tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDO#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end

  def seed_metadata do
    %{identifier: "repo#2278", retry_poll_failures: 0, terminal_membership_pending?: false}
  end
end
