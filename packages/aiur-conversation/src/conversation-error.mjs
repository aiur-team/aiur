const MESSAGES = {
  permission_denied: 'Permission denied.',
  upload_failed: 'Could not upload the attachment.',
  provider_unavailable: 'Voice or dictation is unavailable.',
  send_failed: 'Could not send the message.',
  read_failed: 'Could not load the conversation.',
  answer_failed: 'Could not submit the Command answer.',
};

const FALLBACK = {
  upload: 'upload_failed',
  send: 'send_failed',
  dictation: 'provider_unavailable',
  voice: 'provider_unavailable',
  read: 'read_failed',
  answer: 'answer_failed',
};

/** Normalize adapter failures for controls, live regions and host messages. */
export function conversationError(action, error) {
  const reported = error?.code;
  const code = Object.hasOwn(MESSAGES, reported)
    ? reported
    : error?.name === 'NotAllowedError' || error?.name === 'PermissionDeniedError'
      ? 'permission_denied'
      : FALLBACK[action];
  return { action, code, message: MESSAGES[code], error };
}
