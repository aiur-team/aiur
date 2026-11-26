defmodule Aiur.DecisionStore.HumanConfirmation do
  @moduledoc "A verified human sign-in that the Decision store accepts as the answer to a `gateway_grant`. Only a caller that has verified the sign-in builds one."
  defstruct [:method, :subject, :authenticated_at]
end
