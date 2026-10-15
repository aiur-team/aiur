defmodule AiurWeb.StreamdeckLive.Components do
  @moduledoc """
  Function components for the Stream Deck emulator chassis: the brand bar, the
  key area in each mode (agent grid, command row, settings, logs, Commands),
  the dials and the install modal. Every DOM id, class, `phx-*` and data
  attribute here is a contract with the emulator hook, the browser spec and
  the physical deck's parity checks.
  """

  use Phoenix.Component

  import AiurWeb.StreamdeckLive.CommandKeys, only: [command_keys: 2, commands_history_keys: 2, commands_option_keys: 2]

  alias AiurWeb.OperatorControlCenter.BuildOrderEpicIcon
  alias AiurWeb.{StreamdeckKeyFaceContract, StreamdeckLogs}

  # The web emulator's own drawing routine, fed entirely by the shared key-face
  # contract: a state's colours are stated once, in the contract, and reach the
  # page as CSS custom properties keyed by the same `st-<bucket>` class the
  # packaged deck keys its bitmaps by.
  @key_face_css StreamdeckKeyFaceContract.states()
                |> Enum.sort_by(fn {_bucket, state} -> state["rank"] end)
                |> Enum.map_join("", fn {bucket, state} ->
                  pulse =
                    case state["pulse_seconds"] do
                      seconds when is_number(seconds) ->
                        ".sd-agent-key.st-#{bucket} .sd-ag-dot,.sd-agent-key.st-#{bucket} .sd-ag-stat::before{animation:sd-pulse #{seconds}s ease-in-out infinite;}"

                      _absent ->
                        ""
                    end

                  ".sd-key.st-#{bucket}{--sd-accent:#{state["accent"]};--sd-glow:#{state["glow"]};--sd-face:#{state["face"]};}" <>
                    ".sd-key.st-#{bucket} .sd-key-face{background:var(--sd-face);}" <> pulse
                end)
                |> then(&Phoenix.HTML.raw("<style>" <> &1 <> "</style>"))

  @spec key_face_css() :: Phoenix.HTML.safe()
  def key_face_css, do: @key_face_css

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

  attr(:grid, :map, required: true)
  attr(:grid_page, :integer, required: true)
  attr(:grid_column_offset, :integer, required: true)
  attr(:grid_dial_value, :any, required: true)
  attr(:selected_identifier, :any, required: true)
  attr(:keys, :list, required: true)
  @spec grid_keys(map()) :: Phoenix.LiveView.Rendered.t()
  def grid_keys(assigns) do
    ~H"""
          <div id="sd-keys" class="sd-keys" role="group" data-mode-view="grid" aria-label="Agent keys" data-grid-total={@grid.total} data-grid-windows={@grid.windows} data-grid-page={@grid_page} data-grid-page-count={@grid.windows} data-grid-column-offset={@grid_column_offset} data-grid-dial-value={@grid_dial_value} data-grid-selected-identifier={@selected_identifier}>
            <button
              :for={key <- @keys}
              type="button"
              class={["sd-key", "sd-agent-key", key.empty? && "is-empty", "st-#{key.bucket}"]}
              disabled={key.empty?}
              style={key.style}
              aria-hidden={to_string(key.empty?)}
              data-streamdeck-key={key.slot}
              data-streamdeck-identifier={key.identifier}
              data-control-action={key.control_action}
            >
              <div class={["sd-key-face", !key.empty? && "sd-agent"]}>
                <div :if={!key.empty?} class="sd-agent-top">
                  <BuildOrderEpicIcon.build_order_epic_icon lane={key.icon} class="sd-ag-ic" />
                  <img :if={key.vendor_logo} class="sd-ag-vendor" src={key.vendor_logo} alt="" />
                  <span :if={!key.vendor_logo} class="sd-ag-vendor-fallback" role="img" aria-label="Unknown provider">◌</span>
                  <span class="sd-ag-idwrap">
                    <span :if={key.priority?} class="sd-ag-prio" aria-label="Prioritized">
                      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 3l2.6 5.7 6.2.6-4.7 4.2 1.4 6.1L12 17l-5.5 2.6 1.4-6.1L3.2 9.3l6.2-.6z" /></svg>
                    </span>
                    <span class="sd-ag-id">{key.ticket}</span>
                  </span>
                </div>
                <span :if={!key.empty?} class="sd-ag-title">{key.title}</span>
                <div :if={!key.empty? and key.bucket == "queued"} class="sd-ag-foot col">
                  <span class="sd-ag-stat">{key.label}</span>
                  <span :if={key.dependency_ready?} class="sd-ag-unblocked" role="img" aria-label={key.dependency}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4" y="11" width="12" height="9.5" rx="2" /><path d="M13 11V7a4 4 0 0 1 8 0v2" /></svg>
                  </span>
                  <span :if={!key.dependency_ready?} class="sd-ag-tag blocked">{key.dependency}</span>
                </div>
                <div
                  :if={!key.empty? and key.bucket != "queued"}
                  class={[
                    "sd-ag-foot",
                    is_nil(key.progress) && "is-progress-unknown"
                  ]}
                >
                  <span class="sd-ag-dot" aria-hidden="true"></span>
                  <span class="sr-only">{key.label}</span>
                  <span class="sd-ag-bar" role="progressbar" aria-valuenow={key.progress} aria-valuemin="0" aria-valuemax="100" aria-label={progress_aria_label(key.progress)}><i :if={not is_nil(key.progress)} style={"width: #{key.progress}%"}></i></span>
                </div>
              </div>
            </button>
          </div>
    """
  end

  attr(:sd_active, :any, required: true)
  attr(:mic_held?, :boolean, required: true)
  attr(:selected_identifier, :any, required: true)
  @spec cmd_keys(map()) :: Phoenix.LiveView.Rendered.t()
  def cmd_keys(assigns) do
    ~H"""
          <ul id="sd-keys" class="sd-keys sd-cmd-keys" data-mode-view="cmd" aria-label="Available commands">
            <li :for={key <- command_keys(@sd_active, @mic_held?)} class={["sd-key", "sd-cmd-key", key.mic? && "sd-mic-key", key.mic? && @mic_held? && "mic-live", key.empty? && "is-empty", !key.empty? && key.disabled? && "is-disabled"]} aria-hidden={to_string(key.empty?)}>
              <button :if={!key.empty?} type="button" class="sd-key-face" data-streamdeck-command={key.command} data-command-state={key.state} data-command-hold={key.mic? && "true"} data-streamdeck-identifier={@selected_identifier} disabled={key.disabled?} aria-disabled={to_string(key.disabled?)} aria-label={key.label}>
                <span class="sd-cmd">
                  <span class="sd-cmd-ic" aria-hidden="true">
                    <svg :if={key.icon == "pause"} data-streamdeck-icon="pause" viewBox="0 0 24 24" fill="currentColor" stroke="none"><rect x="6.5" y="5" width="3.6" height="14" rx="1"/><rect x="13.9" y="5" width="3.6" height="14" rx="1"/></svg>
                    <svg :if={key.icon == "play"} data-streamdeck-icon="play" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M8 5.5v13l11-6.5z"/></svg>
                    <svg :if={key.icon == "up"} data-streamdeck-icon="up" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 19V5M6 11l6-6 6 6"/></svg>
                    <svg :if={key.icon == "down"} data-streamdeck-icon="down" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 5v14M6 13l6 6 6-6"/></svg>
                    <svg :if={key.icon == "logs"} data-streamdeck-icon="logs" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 6h16M4 12h16M4 18h10"/></svg>
                    <svg :if={key.icon == "mic"} data-streamdeck-icon="mic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M6 11a6 6 0 0 0 12 0M12 17v4"/></svg>
                    <svg :if={key.icon == "settings"} data-streamdeck-icon="settings" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.2 5.2l1.6 1.6M17.2 17.2l1.6 1.6M18.8 5.2l-1.6 1.6M6.8 17.2l-1.6 1.6"/></svg>
                    <svg :if={key.icon == "commands"} data-streamdeck-icon="commands" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="8.5"/><path d="M9.8 9a2.3 2.3 0 1 1 3.2 2.6c-.9.5-1.2 1-1.2 2"/><path d="M12 17.5h.01"/></svg>
                  </span>
                  <span class="sd-cmd-label">{key.label}</span>
                  <span class="sd-cmd-sub">{key.sub}</span>
                </span>
              </button>
              <button :if={key.empty?} type="button" class="sd-key-face" disabled aria-hidden="true" tabindex="-1"></button>
            </li>
          </ul>
    """
  end

  @spec settings_view(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_view(assigns) do
    ~H"""
          <div id="sd-settings-view" class="sd-settings-view" data-mode-view="settings" role="group" aria-label="Settings">
            <p class="sd-settings-line" data-settings-line="microphone">Microphone selection lives on the machine running the sidecar. The browser emulator has no access to those devices, so there is nothing to choose here.</p>
            <p class="sd-settings-line" data-settings-line="voice">Speech is transcribed by Aiur, not by the deck: audio is streamed to Aiur over the authenticated channel and Aiur calls ElevenLabs. The sidecar never holds the API key.</p>
          </div>
    """
  end

  attr(:sd_active, :map, required: true)
  attr(:logs, :map, required: true)
  @spec logs_view(map()) :: Phoenix.LiveView.Rendered.t()
  def logs_view(assigns) do
    ~H"""
          <div id="sd-logs-view" class="sd-logs-view" data-mode-view="logs" data-focused-identifier={@sd_active.identifier} role="log" aria-label="Agent logs">
            <ul id="sd-log-keys" class="sd-keys sd-log-keys" aria-label="Log event keys" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
              <li
                :for={key <- @logs.event_keys_visible}
                class={["sd-key", "sd-log-key", key.kind == :empty && "is-empty", key.kind == :live && "sd-live-key is-live", key.index == @logs.selected_event_index && "is-selected"]}
                data-log-event-index={key.index}
                aria-hidden={to_string(key.kind == :empty)}
                aria-current={if key.index == @logs.selected_event_index, do: "true", else: "false"}
                aria-label={log_key_label(key)}
                role={if key.kind == :empty, do: nil, else: "button"}
                tabindex={if key.kind == :empty, do: nil, else: "0"}
              >
                <div :if={key.kind == :empty} class="sd-key-face"></div>
                <div :if={key.kind == :live} class="sd-key-face sd-live-key-face">
                  <span class="sd-live-dot" aria-hidden="true"></span>
                  <span class="sd-live-label">{key.text}</span>
                </div>
                <div :if={key.kind == :event} class="sd-key-face sd-log-key-face">
                  <span class="sd-log-dir sd-log-badge" data-dir={key.badge} style={log_badge_style(key.badge)}>{key.badge}</span>
                  <span class="sd-log-text">{key.text}</span>
                  <span class="sd-log-time">{key.time}</span>
                </div>
              </li>
            </ul>
            <%!-- SP-203 turned the event window into the key faces above, so this
                  pane no longer paints event lines. It stays as the event
                  window's state mirror — the same role #sd-log-transcript plays
                  below, both hidden by .sd-log-body — so the offset bounds that
                  drive the dial-D EVENTS hint remain observable. --%>
            <div id="sd-log-events" class="sd-log-body" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
              <span id="sd-events-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset == 0)}>↑</span>
              <span id="sd-events-hint-down" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset >= @logs.events_max_offset)}>↓</span>
            </div>
            <div id="sd-log-transcript" class="sd-log-body" data-offset={@logs.transcript_offset} data-max-offset={@logs.transcript_max_offset}>
              <span id="sd-transcript-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.transcript_offset == 0)}>↑</span>
              <p :for={entry <- @logs.transcript_visible} class="sd-log-line" data-log-kind={entry.kind}>{StreamdeckLogs.line(entry)}</p>
              <p :if={@logs.transcript_visible == []} class="sd-log-line">No recent transcript.</p>
              <span id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden={to_string(@logs.transcript_offset >= @logs.transcript_max_offset)}>↓</span>
            </div>
          </div>
    """
  end

  attr(:sd_active, :map, required: true)
  attr(:commands, :map, required: true)
  attr(:commands_view, :atom, required: true)
  attr(:commands_selection, :any, required: true)
  attr(:commands_option, :any, required: true)
  attr(:commands_offset, :any, required: true)
  @spec commands_view(map()) :: Phoenix.LiveView.Rendered.t()
  def commands_view(assigns) do
    ~H"""
          <div id="sd-commands-view" class="sd-commands-view" data-mode-view="commands" data-focused-identifier={@sd_active.identifier} role="group" aria-label="Agent Commands">
            <ul id="sd-command-keys" class="sd-keys sd-command-keys" aria-label="Command keys" data-commands-view={@commands_view}>
              <%= if @commands_view == :detail and @commands_selection do %>
                <li :for={key <- commands_option_keys(@commands_selection, @commands_offset)} class={["sd-key", "sd-cmd-key", key.empty? && "is-empty", !key.empty? && key.index == @commands_option && "is-selected"]}>
                  <button :if={!key.empty?} type="button" class="sd-key-face" data-command-option={key.index} data-command-selected={key.index == @commands_option && "true"} phx-click="command-select" phx-value-index={key.index} aria-label={"Option: #{key.label}"}>
                    <span class="sd-cmd">
                      <span class="sd-cmd-label">{key.label}</span>
                      <span class="sd-cmd-sub">OPT {key.index + 1}</span>
                    </span>
                  </button>
                  <button :if={key.empty?} type="button" class="sd-key-face" disabled aria-hidden="true" tabindex="-1"></button>
                </li>
                <li class={["sd-key", "sd-cmd-key", "sd-command-mic", "is-disabled"]}>
                  <button type="button" class="sd-key-face" disabled aria-label="Mic">
                    <span class="sd-cmd">
                      <span class="sd-cmd-label">Mic</span>
                      <span class="sd-cmd-sub">SIDECAR</span>
                    </span>
                  </button>
                </li>
              <% else %>
                <li :for={key <- commands_history_keys(@commands, nil)} class={["sd-key", "sd-cmd-key", key.empty? && "is-empty"]}>
                  <button :if={!key.empty?} type="button" class="sd-key-face" data-command-key={key.decision_id} phx-click="command-select" phx-value-index={key.index} aria-label={key.question}>
                    <span class="sd-cmd">
                      <span class="sd-cmd-label">{key.question}</span>
                      <span class="sd-cmd-sub">{key.status}</span>
                    </span>
                  </button>
                  <button :if={key.empty?} type="button" class="sd-key-face" disabled aria-hidden="true" tabindex="-1"></button>
                </li>
              <% end %>
            </ul>
          </div>
    """
  end

  attr(:knobs, :list, required: true)
  @spec knobs(map()) :: Phoenix.LiveView.Rendered.t()
  def knobs(assigns) do
    ~H"""
          <div class="sd-well">
            <div id="sd-knobs" class="sd-knobs" role="group" aria-label="Control dials">
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
            <button type="button" class="tool-btn" phx-click="close-streamdeck-install">Close</button>
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

  defp progress_aria_label(percent) when is_number(percent), do: "#{percent}% complete"
  defp progress_aria_label(_percent), do: "progress unknown"

  defp log_badge_style(badge), do: "--sd-log-badge: #{StreamdeckKeyFaceContract.direction_badge!(badge)["color"]}"

  defp log_key_label(%{kind: :live}), do: "LIVE"
  defp log_key_label(%{kind: :event, badge: badge, text: text, time: time}), do: "#{badge}: #{text}, #{time}"
  defp log_key_label(_key), do: nil

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
