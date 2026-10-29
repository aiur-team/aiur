(() => {
  class ExecutorVoiceController {
    constructor(root) {
      this.root = root;
      this.state = "idle";
      this.sources = new Set();
      this.receipts = new Map();
      this.onToggle = () => {
        if (this.transport && ["failed", "ending"].includes(this.state)) return;
        ["connecting", "live"].includes(this.state) ? this.stop() : this.start();
      };
    }

    bindElements() {
      this.el = this.root.querySelector("[data-executor-voice]");
      const button = this.el?.querySelector("[data-executor-voice-toggle]");
      this.renderReceipts();
      this.bindComparison();
      if (button === this.button) return;
      this.button?.removeEventListener("click", this.onToggle);
      this.button = button;
      this.enabled = button && !button.disabled;
      button?.addEventListener("click", this.onToggle);
    }

    status(state, message) {
      this.state = state;
      if (!this.el) return;
      this.el.dataset.state = state;
      this.el.querySelector("[data-executor-voice-status]").textContent = message;
      this.button.disabled = !this.enabled || this.state === "ending" || (this.state === "failed" && !!this.transport);
      for (const selector of ["[data-executor-voice-provider]", "[data-executor-voice-model]"]) {
        const input = this.el.querySelector(selector);
        if (input) input.disabled = !!this.transport || ["connecting", "live", "ending"].includes(state);
      }
      this.button.textContent = ["connecting", "live"].includes(state) ? "End Executor conversation" : "Talk to Executor";
    }

    async start() {
      if (this.transport) return;
      this.interrupt();
      this.renderReceipts();
      this.el.querySelector("[data-executor-voice-transcript]").textContent = "";
      const generation = this.generation = (this.generation || 0) + 1;
      const current = () => generation === this.generation;
      this.status("connecting", "Connecting to Executor voice…");
      try {
        this.playback ||= new window.AudioContext();
        await this.playback.resume();
        const stream = await window.AiurVoiceCapture.requestMicrophone(window.AiurVoiceCapture.recalledDevice());
        if (!current()) { stream.getTracks().forEach(track => track.stop()); return; }
        const capture = this.capture = new window.AiurVoiceCapture.Capture(stream, samples => {
          if (current() && this.state === "live") this.transport.push("audio", {data: window.AiurVoiceCapture.encodePcm16Base64(samples)});
        });
        this.transport = window.AiurVoiceTransport.open({
          topic: "voice:executor",
          joinPayload: () => ({provider: this.el.querySelector("[data-executor-voice-provider]")?.value,
            model: this.el.querySelector("[data-executor-voice-model]")?.value}),
          handlers: {
            state: payload => current() && this.providerState(payload.state),
            audio: payload => current() && this.playAudio(payload),
            interruption: () => current() && this.interrupt(),
            transcript: payload => { if (current()) this.el.querySelector("[data-executor-voice-transcript]").textContent = `${payload.role}: ${payload.text}`; },
            comparison_saved: () => this.receiptTransport?.push("comparison_list"),
            receipt: payload => { if (current()) this.receipt(payload); },
            ended: () => current() && this.ended(),
            error: payload => current() && this.providerError(payload.reason || "Executor voice failed."),
            handoff_failed: payload => current() && this.fail(payload.reason),
          },
          onError: () => current() && this.fail("Executor voice connection failed."),
          onClose: () => { if (current() && !["ended", "failed"].includes(this.state)) this.fail("Executor voice disconnected before a handoff receipt arrived."); }
        });
        await this.transport.joined;
        this.receiptTransport?.push("comparison_list");
        const active = () => current() && this.capture === capture && ["connecting", "live"].includes(this.state);
        if (!active()) return;
        await capture.start(active);

      } catch (error) {
        if (current() && ["connecting", "live"].includes(this.state)) this.fail(error.message || "Executor voice could not start.");
      }
    }

    stop() {
      this.capture?.stop();
      this.capture = null;
      this.interrupt();
      if (this.transport) {
        this.transport.push("stop");
        this.status("ending", "Ending conversation; waiting for the Executor handoff receipt…");
      } else {
        this.generation = (this.generation || 0) + 1;
        this.status("ended", "Executor voice ended.");
      }
    }

    receipt(payload) {
      if (!Number.isSafeInteger(payload.id) || payload.id <= 0) return;
      const previous = this.receipts.get(payload.id);
      this.receipts.set(payload.id, {...previous, ...payload, ack_status: previous?.ack_status || "waiting"});
      this.renderReceipts();
      this.watchReceipts(payload.id);
    }

    receiptStatus(payload) {
      const previous = this.receipts.get(payload.id);
      if (!previous || previous.ack_status === "received") return;
      this.receipts.set(payload.id, {...previous, ...payload});
      this.renderReceipts();
    }

    renderReceipts() {
      if (!this.el) return;
      const messages = {waiting: "waiting for Executor acknowledgement", missing: "handoff wake missing; no acknowledgement",
        unavailable: "acknowledgement unavailable; no received receipt"};
      const rows = [...this.receipts.values()].map(item => {
        const sent = `SENT — receipt ${item.id} at ${item.at}.`;
        const ack = item.ack_status === "received"
          ? `RECEIVED — wake ${item.wake_id}; ack observed at ${item.observed_at}.`
          : `SENT NOT RECEIVED — ${messages[item.ack_status] || messages.unavailable}.`;
        const summary = item.summary_status === "unstructured" ? "Summary: unstructured (no valid summary recorded)." : "";
        return [sent, ack, summary].filter(Boolean).join("\n");
      });
      this.el.querySelector("[data-executor-voice-receipt]").textContent = rows.join("\n\n");
    }

    pendingReceipts() {
      return [...this.receipts.values()].filter(item => item.ack_status !== "received").map(item => item.id).slice(-20);
    }

    receiptUnavailable() {
      if (this.comparisonEnabled) {
        this.el.querySelector("[data-executor-voice-meter]").textContent = "Comparison usage unavailable.";
        this.comparisonStatus("Comparison connection unavailable. Reload to reconnect before rating a session.");
      }
      for (const id of this.pendingReceipts()) this.receiptStatus({id, ack_status: "unavailable"});
    }

    watchReceipts(id) {
      if (this.receiptTransport) { if (id) this.receiptTransport.push("watch", {id}); return; }
      if (!window.AiurVoiceTransport) { this.receiptUnavailable(); return; }
      let transport;
      const current = () => this.receiptTransport === transport && !this.destroyed;
      transport = window.AiurVoiceTransport.open({
        topic: "voice:executor_receipts",
        joinPayload: () => ({event_ids: this.pendingReceipts()}),
        handlers: {receipt_status: payload => current() && this.receiptStatus(payload),
          comparison: payload => current() && this.renderComparison(payload),
          comparison_error: payload => current() && this.comparisonStatus(payload.reason)},
        onError: () => current() && this.receiptUnavailable(),
        onClose: () => current() && this.receiptUnavailable()
      });
      this.receiptTransport = transport;
      transport.joined.then(() => current() && this.comparisonEnabled && transport.push("comparison_list"))
        .catch(() => current() && this.receiptUnavailable());
    }

    bindComparison() {
      if (this.el?.dataset.configured !== "true" || this.comparisonEl === this.el) return;
      this.comparisonEl = this.el;
      this.comparisonEnabled = true;
      if (this.receiptTransport) this.receiptTransport.push("comparison_list");
      else this.watchReceipts();
    }

    comparisonStatus(message) {
      const field = this.el?.querySelector("[data-executor-voice-comparison-status]");
      if (field) field.textContent = message;
    }

    renderComparison({rows, meters}) {
      if (!this.comparisonEnabled || !Array.isArray(rows) || !Array.isArray(meters)) return;
      this.el.querySelector("[data-executor-voice-meter]").textContent = meters.map(meter =>
        `${meter.provider === "openai_realtime" ? "OpenAI" : "ElevenLabs"}: ${(meter.used_seconds / 60).toFixed(2)} / ${meter.cap_seconds / 60} min used or reserved`
      ).join(" · ");
      const body = this.el.querySelector("[data-executor-voice-comparisons]");
      body.replaceChildren();
      const groups = ["elevenlabs_agents", "openai_realtime"].map(provider => rows.filter(row => row.provider === provider));
      for (let i = 0; i < Math.max(1, ...groups.map(group => group.length)); i++) {
        const tr = document.createElement("tr");
        for (const group of groups) {
          const cell = document.createElement("td");
          group[i] ? this.comparisonCell(cell, group[i]) : cell.textContent = "No session";
          tr.append(cell);
        }
        body.append(tr);
      }
      this.comparisonStatus("Comparison saved on this runtime. Ratings and notes are retained beside transcripts.");
    }

    comparisonCell(cell, row) {
      const metrics = document.createElement("p");
      const first = row.first_audio_ms == null ? "unavailable" : `${row.first_audio_ms} ms`;
      const duration = row.minutes == null ? "reserved / interrupted" : `${row.minutes.toFixed(2)} min`;
      const cost = row.estimated_cost_usd == null ? "unavailable" : `USD ${row.estimated_cost_usd.toFixed(2)} estimate`;
      metrics.textContent = `${row.at} · ${row.model} · First audio: ${first} · ${duration} · ${cost}`;
      cell.append(metrics);
      if (row.status !== "ended") return;
      const rating = document.createElement("select");
      rating.setAttribute("aria-label", `Kevin’s rating for ${row.provider} ${row.at}`);
      for (const value of ["", "1", "2", "3", "4", "5"]) {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = value ? `${value} / 5` : "Choose rating";
        rating.append(option);
      }
      rating.value = row.rating == null ? "" : String(row.rating);
      const note = document.createElement("textarea");
      note.setAttribute("aria-label", `Kevin’s note for ${row.provider} ${row.at}`);
      note.maxLength = 2000;
      note.value = row.note || "";
      const save = document.createElement("button");
      save.type = "button";
      save.className = "aiur-button aiur-button--dashboard btn";
      save.textContent = "Save rating and note";
      save.addEventListener("click", () => {
        this.comparisonStatus("Saving rating…");
        this.receiptTransport?.push("comparison_rate", {id: row.id, rating: Number(rating.value), note: note.value});
      });
      cell.append(rating, note, save);
    }

    ended() {
      if (this.state !== "failed") this.status("ended", "Executor voice ended.");
      this.cleanup(false);
      this.receiptTransport?.push("comparison_list");
      this.status(this.state, this.el.querySelector("[data-executor-voice-status]").textContent);
    }

    providerState(state) {
      if (!["connecting", "live"].includes(this.state)) return;
      if (["listening", "speaking", "thinking"].includes(state)) {
        this.status("live", "Executor voice live. End the conversation to queue its transcript and summary.");
      } else if (["connecting", "reconnecting"].includes(state)) {
        this.status("connecting", "Connecting to Executor voice…");
      }
    }

    providerError(message) {
      this.status("failed", message);
      this.capture?.stop();
      this.capture = null;
      this.interrupt();
    }

    fail(message) {
      this.status("failed", message);
      this.cleanup();
      this.status("failed", message);
    }

    playAudio({data, format}) {
      if (!["connecting", "live"].includes(this.state)) return;
      const rate = {pcm_16000: 16000, pcm_24000: 24000, pcm_44100: 44100}[format];
      if (!rate) return this.fail("Executor voice returned an unsupported audio format.");
      const raw = window.atob(data);
      if (raw.length % 2) return this.fail("Executor voice returned invalid PCM audio.");
      const bytes = Uint8Array.from(raw, char => char.charCodeAt(0));
      const pcm = new DataView(bytes.buffer);
      const buffer = this.playback.createBuffer(1, bytes.length / 2, rate);
      const samples = buffer.getChannelData(0);
      for (let i = 0; i < samples.length; i++) samples[i] = pcm.getInt16(i * 2, true) / 32768;
      const source = this.playback.createBufferSource();
      source.buffer = buffer;
      source.connect(this.playback.destination);
      this.sources.add(source);
      source.onended = () => this.sources.delete(source);
      const at = Math.max(this.playback.currentTime, this.nextAudioAt || 0);
      source.start(at);
      this.nextAudioAt = at + buffer.duration;
    }

    interrupt() {
      for (const source of this.sources) { try { source.stop(); } catch (_) {} }
      this.sources.clear();
      this.nextAudioAt = 0;
    }

    cleanup(stopPlayback = true) {
      this.capture?.stop();
      this.capture = null;
      if (stopPlayback) this.interrupt();
      const transport = this.transport;
      this.transport = null;
      if (this.button) this.button.disabled = !this.enabled;
      transport?.close();
    }

    destroy() {
      this.destroyed = true;
      this.receiptTransport?.close();
      this.receiptTransport = null;
      this.generation = (this.generation || 0) + 1;
      this.button?.removeEventListener("click", this.onToggle);
      this.cleanup();
      this.playback?.close();
    }
  }
  window.AiurExecutorVoiceController = ExecutorVoiceController;
})();
