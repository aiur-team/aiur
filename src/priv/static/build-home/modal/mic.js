const UNKNOWN = 'Dictation availability is not known. Reconnect to the dashboard, then try again.';
const CHECKING = 'Checking whether dictation is available…';

export function mountMic(root, ctx) {
  const mic = root.querySelector('#cv-mic');
  if (!mic) return { rebind() {}, destroy() {} };

  let voice = null, dead = false;
  off(mic, CHECKING);

  ctx.push('voice-availability', {}).then(reply => {
    if (dead || !root.isConnected) return;
    const Controller = window.AiurConversationVoiceController;
    if (reply?.state !== 'available' || !Controller) return off(mic, reply?.reason || UNKNOWN);
    mic.disabled = false;
    mic.title = 'Dictate';
    mic.removeAttribute('aria-disabled');
    voice = new Controller({ el: root });
    voice.mount();
  }, () => {
    if (!dead && root.isConnected) off(mic, UNKNOWN);
  });

  return {
    rebind() { voice?.bindElements(); },
    destroy() { dead = true; voice?.destroy(); voice = null; }
  };
}

function off(mic, reason) {
  mic.disabled = true;
  mic.classList.remove('rec');
  mic.title = reason;
  mic.setAttribute('aria-label', 'Dictate (unavailable)');
  mic.setAttribute('aria-disabled', 'true');
}
