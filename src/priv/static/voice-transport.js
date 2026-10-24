(() => {
  // Joins one voice channel. handlers maps channel events to callbacks;
  // `joined` settles with the join reply.
  function open({ path = "/voice", topic, joinPayload = {}, handlers = {}, onError, onClose }) {
    const VoiceSocket = window.AiurVoiceSocket || window.Phoenix?.Socket;
    if (!VoiceSocket) throw new Error("Dashboard voice connection is unavailable.");

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
    const socket = new VoiceSocket(path, { params: { _csrf_token: csrfToken } });
    socket.connect();
    const channel = socket.channel(topic, joinPayload);
    for (const [event, handler] of Object.entries(handlers)) channel.on(event, handler);
    if (onError) channel.onError(onError);
    if (onClose) channel.onClose(onClose);

    const joined = new Promise((resolve, reject) => {
      channel.join()
        .receive("ok", resolve)
        .receive("error", (reason) => reject(new Error(reason?.reason || "Speech-to-text could not start.")))
        .receive("timeout", () => reject(new Error("Speech-to-text connection timed out.")));
    });

    return {
      socket,
      channel,
      joined,
      push: (event, payload = {}) => channel.push(event, payload),
      close() {
        channel.leave();
        socket.disconnect();
      }
    };
  }

  window.AiurVoiceTransport = { open };
})();
