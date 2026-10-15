defmodule AiurWeb.StreamdeckLive.ScreenComponents do
  @moduledoc """
  The Stream Deck emulator's touch strip: the focused-command panel, the logs
  transcript, the Commands readout, and the grid's summary, provider-meter and
  pager segments.
  """

  use Phoenix.Component

  import AiurWeb.StreamdeckLive.CommandKeys, only: [commands_panel: 1]

  alias AiurWeb.StreamdeckStrip

  attr(:sd_mode, :atom, required: true)
  attr(:screen, :list, required: true)
  attr(:logs, :map, required: true)
  attr(:sd_active, :any, required: true)
  attr(:commands, :map, required: true)
  attr(:commands_view, :atom, required: true)
  attr(:commands_selection, :any, required: true)
  attr(:commands_option, :any, required: true)
  attr(:commands_offset, :any, required: true)
  attr(:commands_page_index, :any, required: true)
  @spec screen(map()) :: Phoenix.LiveView.Rendered.t()
  def screen(assigns) do
    ~H"""
          <div
            id="sd-screen"
            class={["sd-screen", "sd-screen-#{@sd_mode}"]}
            style={"--sd-screen-segments: #{length(@screen)}"}
            data-transcript-offset={@logs.transcript_offset}
            data-transcript-max-offset={@logs.transcript_max_offset}
            role="group"
            aria-label="Touch strip"
          >
            <%= if @sd_mode == :cmd do %>
            <% command = StreamdeckStrip.command(@sd_active) %>
            <div
              class={[
                "sd-strip-cmd",
                "st-#{@sd_active.bucket}",
                command.progress_freshness == :unknown && "is-progress-unknown"
              ]}
              style={"--sd-accent: #{command.accent}"}
              data-mode-view="cmd-strip"
            >
              <div class="sd-strip-cmd-heading">
                <span class="sd-strip-cmd-agent-icon" aria-hidden="true">{command.icon}</span>
                <img :if={command.provider_logo} class="sd-cmd-provider-logo" src={command.provider_logo} alt={command.provider} />
                <span class="sd-strip-cmd-provider">{String.upcase(command.provider)}</span>
                <span class="sd-strip-cmd-pager">CONTROLLING #{command.number}</span>
              </div>
              <div class="sd-strip-cmd-body">
                <span class="sd-strip-cmd-ticket">#{command.number}</span>
                <span class="sd-strip-cmd-title">{command.title}</span>
                <span class="sd-strip-cmd-status">{command.status}</span>
                <span class="sd-strip-cmd-percent">{progress_text(command.percent)}</span>
              </div>
              <span class="sd-strip-cmd-progress" role="progressbar" aria-valuenow={command.percent} aria-valuemin="0" aria-valuemax="100">
                <i :if={not is_nil(command.percent)} style={"width: #{command.percent}%; background: #{command.progress_colour}"}></i>
              </span>
            </div>
            <% end %>
            <div :if={@sd_mode == :logs} class="sd-strip-logs" data-mode-view="logs-strip">
              <div :for={entry <- StreamdeckStrip.entries(@logs.transcript_visible)} class={["sd-log-strip-entry", "sd-log-entry-#{entry.shape}"]} data-log-kind={entry.shape}>
                <div :if={entry.shape == :evhdr} class="sd-log-evhdr">
                  <span class="sd-log-evhdr-direction" style={"color: #{entry.colour}"}>{entry.direction}</span>
                  <span class="sd-log-evhdr-text">{entry.text}</span>
                  <span class="sd-log-evhdr-time">{entry.time}</span>
                </div>
                <div :if={entry.shape == :diff} class="sd-log-diff">
                  <span class="sd-log-diff-file">{entry.file}</span>
                  <span class="sd-log-diff-counts"><b>+{entry.additions}</b> <b>-{entry.deletions}</b></span>
                  <code class={["sd-log-diff-line", "is-#{entry.line_kind}"]}>{entry.line}</code>
                </div>
                <div :if={entry.shape == :diff_line} class="sd-log-diff">
                  <code class={["sd-log-diff-line", "is-#{entry.line_kind}"]}>{entry.line}</code>
                </div>
                <div :if={entry.shape == :message} class={["sd-log-message", "is-#{entry.kind}"]}>
                  <span :if={entry.glyph} class="sd-log-glyph" aria-hidden="true">{entry.glyph}</span>
                  <span class="sd-log-message-text">{entry.text}</span>
                </div>
              </div>
              <p :if={@logs.transcript_visible == []} class="sd-log-strip-empty">No recent transcript.</p>
            </div>
            <%= if @sd_mode == :commands do %>
            <% commands_panel = commands_panel(assigns) %>
            <div class="sd-strip-commands" data-mode-view="commands-strip" data-commands-view={commands_panel.view}>
              <%= if commands_panel.view == "history" do %>
                <div class="sd-strip-commands-heading">
                  <span class="sd-strip-commands-title">COMMANDS</span>
                  <span class="sd-strip-commands-status" data-commands-active={commands_panel.active}>
                    <%= if commands_panel.unavailable? do %>UNAVAILABLE<% else %><%= commands_panel.active %> OPEN<% end %>
                  </span>
                </div>
                <p class="sd-strip-commands-reading"><%= commands_panel.note %></p>
                <span class="sd-strip-commands-page"><%= if commands_panel.has_next?, do: "page #{commands_panel.page_index + 1} · dial D for more", else: "" %></span>
              <% else %>
                <div class="sd-strip-commands-heading">
                  <span class="sd-strip-commands-status" data-commands-status={commands_panel.status}><%= commands_panel.status %></span>
                  <span class="sd-strip-commands-ticket"><%= @sd_active.identifier %></span>
                </div>
                <p class="sd-strip-commands-title"><%= commands_panel.question %></p>
                <p class="sd-strip-commands-reading"><%= commands_panel.reading %></p>
                <span class="sd-strip-commands-note"><%= commands_panel.note %></span>
              <% end %>
            </div>
            <% end %>
            <div
              :for={segment <- @screen}
              :if={@sd_mode == :grid or segment.kind == :pager}
              class={[
                "sd-screen-segment",
                "sd-seg",
                if(segment.kind == :pager, do: "sd-seg-d", else: "sd-seg-info"),
                segment.observed? && "is-live"
              ]}
              data-segment={segment.kind}
            >
              <span :if={segment.kind == :pager} class="sd-seg-dlabel">{segment.label}</span>

              <div :if={segment.kind != :pager} class="sd-info-hd">

                <img class="sd-hd-logo" src={segment.logo} alt="" aria-hidden="true" />
                <span>{segment.label}</span>
                <span :if={segment.kind == :provider and segment.provider == "claude"} class="sd-mic" aria-hidden="true"></span>
              </div>

              <div :if={segment.kind == :summary} class="sd-info-live">
                <b>{segment.live}</b> live · <b>{segment.remaining}</b> left
              </div>

              <div :if={segment.kind == :summary} class="sd-mini" data-meter="build" data-observed="false">
                <span class="sd-mini-top">
                  <span class="sd-mini-lbl">Build</span>
                  <span class="sd-mini-r"></span>
                </span>
                <span class="sd-mini-bar" role="img" aria-label="Build progress unavailable"><i></i></span>
              </div>

              <div
                :for={meter <- segment.meters}
                :if={segment.kind == :provider}
                class={["sd-mini", meter.observed? && "is-observed"]}
                data-provider={segment.provider}
                data-meter={meter.key}
                data-percent={meter.percent}
                data-observed={to_string(meter.observed?)}
                data-freshness={meter.freshness}
              >
                <span class="sd-mini-top">
                  <span class="sd-mini-lbl">{meter.label}</span>
                  <span :if={meter.observed?} class="sd-mini-r">{meter.percent}%<span :if={meter.metadata}> · {meter.metadata}</span></span>
                  <span :if={!meter.observed?} class="sd-mini-r"></span>
                </span>
                <span class="sd-mini-bar" role="img" aria-label={meter_aria_label(meter)}><i :if={meter.observed?} style={"width: #{meter.percent}%"}></i></span>
              </div>

              <div :if={segment.kind == :pager} class="sd-pager" role="group" aria-label={if segment.focus_label, do: "Controlled agent", else: "Agent pages"}>
                <span
                  :for={page <- segment.pages}
                  class={["sd-pager-dot", page == segment.current_page && "is-active"]}
                  data-pager-page={page}
                  aria-current={if page == segment.current_page, do: "page", else: nil}
                ></span>
                <span :if={segment.focus_label} class="sd-pager-label" data-pager-focus={segment.focus_label}>{segment.focus_label}</span>
              </div>
            </div>
          </div>
    """
  end

  defp meter_aria_label(%{label: label, observed?: true, percent: percent, metadata: metadata}) do
    Enum.reject([label, "#{percent}%", metadata], &is_nil/1) |> Enum.join(" · ")
  end

  defp meter_aria_label(%{label: label}), do: "#{label} unavailable"

  defp progress_text(percent) when is_number(percent), do: "#{percent}%"
  defp progress_text(_percent), do: "—"
end
