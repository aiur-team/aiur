defmodule Aiur.Orchestrator.Effect do
  @moduledoc "Transition requests interpreted synchronously by TicketTransition."

  @type t ::
          {:terminate, String.t(), boolean()}
          | {:resume_paused, map(), boolean()}
          | {:reactivate, map()}
          | {:transition_control, map(), atom(), term()}
          | {:preserve_on_external_error, Aiur.Issue.t()}
          | {:pause_for_ci_wait, Aiur.Issue.t()}
          | {:maybe_deactivate_human_review, Aiur.Issue.t()}
end
