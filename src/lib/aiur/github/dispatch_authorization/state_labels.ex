defmodule Aiur.GitHub.DispatchAuthorization.StateLabels do
  @moduledoc false

  alias Aiur.Issue

  # Two state labels are a transient relabel window (add the new label, then
  # remove the old one) or a lifecycle bug, and the dispatch policy resolves
  # them to one state. The ticket is authorized only when every state label is:
  # each label's provenance is checked on its own, and one untrusted applier
  # denies the ticket. Stops at the first denial so a hostile label costs no
  # further timeline reads.
  @spec authorize(Issue.t(), (Issue.t() -> Issue.t()), (Issue.t(), term() -> Issue.t())) :: Issue.t()
  def authorize(%Issue{state_labels: state_labels} = issue, authorize_one, deny) do
    verdict =
      Enum.reduce_while(state_labels, :authorized, fn state, verdict ->
        case authorize_one.(%{issue | state: state, state_labels: [state]}).dispatch_authorization do
          :authorized -> {:cont, verdict}
          :deferred -> {:cont, :deferred}
          _denied -> {:halt, :denied}
        end
      end)

    case verdict do
      :denied -> deny.(issue, {:contradictory_state_labels, state_labels})
      verdict -> %{issue | dispatch_authorized?: verdict == :authorized, dispatch_authorization: verdict}
    end
  end
end
