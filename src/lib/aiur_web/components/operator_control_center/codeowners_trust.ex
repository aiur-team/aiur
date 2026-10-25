defmodule AiurWeb.OperatorControlCenter.CodeownersTrust do
  @moduledoc false
  use Phoenix.Component

  alias Aiur.GitHub.TrustSnapshot

  attr(:now, :any, required: true)
  attr(:snapshot, :any, default: nil)

  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(assigns) do
    snapshot = assigns.snapshot || TrustSnapshot.current()
    assigns = assign(assigns, :detail, if(snapshot, do: TrustSnapshot.status_suffix(snapshot, assigns.now), else: ""))

    ~H"""
    <div :if={@detail != ""} id="codeowners-trust-degraded" class="readonly-banner" role="status" aria-live="polite">
      <span><b>CODEOWNERS trust degraded.</b> {@detail}</span>
    </div>
    """
  end
end
