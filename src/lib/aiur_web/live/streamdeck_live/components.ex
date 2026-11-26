defmodule AiurWeb.StreamdeckLive.Components do
  @moduledoc "HTML chassis, dials and installation dialog for the Stream Deck emulator."
  use Phoenix.Component

  @spec brand(map()) :: Phoenix.LiveView.Rendered.t()
  def brand(assigns) do
    ~H"""
          <header class="sd-brand">
            <svg class="sd-brand-logo" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <circle cx="12" cy="12" r="9" stroke="#fff" stroke-width="2" />
              <path d="M15 12a3 3 0 1 0-3 3" stroke="#fff" stroke-width="2" fill="none" />
              <circle cx="12" cy="12" r="2" fill="#fff" />
            </svg>
            <span class="sd-brand-name">STREAM DECK</span>
            <div class="sd-package-controls">
              <button
                id="streamdeck-download-control"
                class="sd-install-control"
                type="button"
                phx-click="open-streamdeck-install"
              >
                Download
              </button>
            </div>
          </header>
    """
  end

  attr(:knobs, :list, required: true)
  @spec knobs(map()) :: Phoenix.LiveView.Rendered.t()
  def knobs(assigns) do
    ~H"""
          <div class="sd-well">
            <div id="sd-knobs" class="sd-knobs" style="width: 800px;" role="group" aria-label="Control dials">
              <div :for={{knob, idx} <- Enum.with_index(@knobs)} class="sd-knob-wrap">
                <div
                  class="sd-knob"
                  style={"--a: #{knob.angle}deg; touch-action: none;"}
                  role="slider"
                  tabindex="0"
                  aria-label={knob_aria_label(knob, idx)}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow={knob.value}
                  data-value={knob.value}
                >
                </div>
                <span :if={knob.hint} class="sd-dial-hint">
                  <span style={"visibility: " <> if(knob.hint.older?, do: "visible", else: "hidden")}>‹</span>{knob.hint.label}<span style={"visibility: " <> if(knob.hint.newer?, do: "visible", else: "hidden")}>›</span>
                </span>
              </div>
            </div>
          </div>
    """
  end

  attr(:install_modal?, :boolean, required: true)
  attr(:streamdeck_package, :any, required: true)
  attr(:os, :atom, required: true)
  @spec install_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def install_modal(assigns) do
    ~H"""
      <div :if={@install_modal?} class="modal-backdrop sd-install-backdrop">
        <section
          id="streamdeck-install-modal"
          class="modal-panel sd-install-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="streamdeck-install-title"
          phx-click-away="close-streamdeck-install"
          phx-hook="TicketContextDialog"
          data-close-event="close-streamdeck-install"
          data-origin-id="streamdeck-download-control"
        >
          <header class="modal-header">
            <h2 id="streamdeck-install-title" class="sd-install-title" tabindex="-1" data-dialog-heading>Install on your Stream Deck +</h2>
            <button type="button" class="aiur-button aiur-button--tool aiur-button--dashboard-tool tool-btn" phx-click="close-streamdeck-install">Close</button>
          </header>

    <!-- `list-style: none` plus `display: grid` drops list semantics in some
               screen readers; the explicit roles put them back. -->
          <ol class="sd-install-steps" role="list">
            <li class="sd-install-step" role="listitem">
              <h3 class="sd-install-step-title">Step 1: Download the package</h3>
              <a :if={package?(@streamdeck_package)} class="sd-install-download" href={@streamdeck_package.url} download>
                Download the package
              </a>
              <p :if={!package?(@streamdeck_package)} class="sd-install-note">
                No Stream Deck + package is published for this release. Step 2 builds and installs the sidecar from source instead.
              </p>
            </li>

            <li class="sd-install-step" role="listitem">
              <h3 class="sd-install-step-title">Step 2: Paste this into your agent chat</h3>
              <div id="streamdeck-install-prompt-copy" class="sd-install-prompt" phx-hook="CopyToClipboard">
                <%!-- No `tabindex`: the block wraps rather than scrolls, so a tab stop here
                      would be an unnamed stop inside the dialog's focus trap. --%>
                <pre id="streamdeck-install-prompt" class="sd-install-prompt-text" data-copy-source>{install_prompt(@os)}</pre>
                <div class="sd-install-prompt-actions">
                  <button type="button" class="sd-install-copy-button" data-copy-trigger>Copy prompt</button>
                  <span id="streamdeck-install-prompt-status" role="status" aria-live="polite" data-copy-status></span>
                </div>
              </div>
            </li>
          </ol>

          <p :if={@os == :windows} class="sd-install-note">Windows isn't fully supported yet; the README documents the Linux and macOS paths.</p>
        </section>
      </div>
    """
  end

  # Dial 0 presses BACK, dial 3 cycles the focused window. Labels convey this.
  defp knob_aria_label(%{label: label, value: value}, 0),
    do: "#{label}: #{value} — press to go back"

  defp knob_aria_label(%{label: label, value: value}, 3),
    do: "#{label}: #{value} — press to cycle window"

  defp knob_aria_label(%{label: label, value: value}, _),
    do: "#{label}: #{value}"

  defp package?(%{url: url}) when is_binary(url) and url != "", do: true
  defp package?(_package), do: false

  defp os_label(:windows), do: "Windows"
  defp os_label(:mac), do: "macOS"
  defp os_label(_linux), do: "Linux"

  # Step 2's payload. It renders in a soft-wrapping block rather than a fixed-row
  # textarea so the whole prompt is visible over as many wrapped rows as it
  # needs, at every width, instead of running off the right edge of the dialog.
  defp install_prompt(os) do
    "Walk me through installing the Aiur Stream Deck + sidecar on #{os_label(os)}. " <>
      "Follow packages/streamdeck/README.md exactly and give me copy-pasteable commands for each step."
  end
end
