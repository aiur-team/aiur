/**
 * Renders the Command component contract from Aiur's ticket-scoped Commands API.
 *
 * The renderer is deliberately dependency-free and returns HTML strings: a
 * host can drop the markup into any document, and a server can render it
 * without a DOM. Every state the dashboard knows about has a stable
 * `data-command-state` token, so host styling and host tests key off the same
 * vocabulary Aiur uses.
 */

/** Every Command-level state the contract can carry. */
export const COMMAND_STATES = ['pending', 'answered', 'revised', 'expired', 'unavailable', 'conflict', 'error'];

/** Every list-level state the contract can carry. */
export const LIST_STATES = ['loading', 'empty', 'ready', 'unavailable', 'error'];

const STATE_LABELS = {
  pending: 'Awaiting your answer',
  answered: 'Answered',
  revised: 'Answer revised',
  expired: 'No longer answerable',
  unavailable: 'Command state unavailable',
  conflict: 'Answer conflict',
  error: 'Command error',
};

const LIST_COPY = {
  loading: 'Loading Commands…',
  empty: 'No Commands need you right now.',
  unavailable: 'Command state is unavailable right now.',
  error: 'Commands could not be loaded.',
};

const STATE_ORDER = ['conflict', 'error', 'unavailable', 'expired', 'revised', 'answered', 'pending'];

/** The human label for a Command or list state. */
export function stateLabel(state) {
  return STATE_LABELS[state] ?? 'Command';
}

/** Escapes text for safe interpolation into HTML. */
export function escapeHtml(value) {
  if (value === null || value === undefined) return '';
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function stateOf(command) {
  return STATE_ORDER.find((state) => state === command?.state) ?? 'error';
}

function reasonAttribute(command) {
  return command?.reason ? ` data-command-reason="${escapeHtml(command.reason)}"` : '';
}

function ticketLine(command) {
  if (!command?.ticket) return '';
  const identifier = command.ticket.identifier ? `#${escapeHtml(command.ticket.identifier)}` : '';
  const title = command.ticket.title ? escapeHtml(command.ticket.title) : '';
  const text = [identifier, title].filter(Boolean).join(' ');
  if (!text) return '';
  const body = command.ticket.url
    ? `<a href="${escapeHtml(command.ticket.url)}">${text}</a>`
    : text;
  return `<p class="aiur-command-ticket">${body}</p>`;
}

function recommendationLine(command) {
  if (!command?.recommendation) return '';
  return `<p class="aiur-command-recommendation" data-command-recommendation="${escapeHtml(command.recommendation.option_id)}">Recommended: ${escapeHtml(command.recommendation.label ?? command.recommendation.option_id)}</p>`;
}

function optionsMarkup(command) {
  if (!Array.isArray(command?.options) || command.options.length === 0) return '';

  const items = command.options
    .map((option) => {
      const recommended = command.recommendation?.option_id === option.id;
      const checked = recommended ? ' checked' : '';
      const description = option.description
        ? `<small>${escapeHtml(option.description)}</small>`
        : '';
      const badge = recommended ? '<span class="aiur-command-chip">Recommended</span>' : '';

      return `<label class="aiur-command-option${recommended ? ' is-recommended' : ''}" data-option-id="${escapeHtml(option.id)}">
  <input type="radio" name="option_id" value="${escapeHtml(option.id)}"${checked}>
  <span class="aiur-command-option-copy"><strong>${escapeHtml(option.label)}</strong>${description}</span>${badge}
</label>`;
    })
    .join('\n');

  return `<fieldset class="aiur-command-options"><legend>Choose an answer</legend>\n${items}\n</fieldset>`;
}

function freeResponseMarkup(command) {
  if (!command?.free_response?.allowed) return '';

  const required = command.free_response.required ? ' required' : '';

  return `<label class="aiur-command-response">
  <span>Response</span>
  <textarea name="custom_response" rows="4" maxlength="4000"${required} placeholder="State the Command response clearly…"></textarea>
</label>`;
}

function answerMarkup(command) {
  if (!command?.answer) return '';

  const label = command.answer.selected_option_id
    ? escapeHtml(command.answer.selected_option_id)
    : escapeHtml(command.answer.custom_response ?? 'Answer recorded');

  return `<div class="aiur-command-answer" data-action-id="${escapeHtml(command.answer.action_id)}">
  <span class="aiur-command-answer-label">${stateOf(command) === 'revised' ? 'Revised answer' : 'Recorded answer'}</span>
  <strong>${label}</strong>
</div>`;
}

function conflictMarkup(command) {
  if (stateOf(command) !== 'conflict') return '';

  const winner = command.conflict?.winner;
  const copy = winner?.actor
    ? `Already answered by ${escapeHtml(winner.actor)}.`
    : 'Another answer already won. Refresh to see the current state.';

  return `<p class="aiur-command-conflict" role="status">${copy}</p>`;
}

function mediaMarkup(command) {
  if (!Array.isArray(command?.media) || command.media.length === 0) return '';

  const items = command.media
    .map((entry) => {
      if (entry.kind === 'url' && /^https:\/\//.test(entry.value)) {
        return `<a class="aiur-command-media" href="${escapeHtml(entry.value)}" rel="noreferrer noopener">${escapeHtml(entry.value)}</a>`;
      }

      return `<span class="aiur-command-media" data-media-kind="${escapeHtml(entry.kind)}">${escapeHtml(entry.value)}</span>`;
    })
    .join('\n');

  return `<div class="aiur-command-media-list">\n${items}\n</div>`;
}

function pendingForm(command, options) {
  if (stateOf(command) !== 'pending' || command?.actions?.answer !== true) return '';

  const action = options.answerUrl
    ? ` action="${escapeHtml(options.answerUrl)}"`
    : '';
  const method = options.method ?? 'post';

  return `<form class="aiur-command-answer-form" data-aiur-command-form data-decision-id="${escapeHtml(command.decision_id)}" method="${escapeHtml(method)}"${action}>
  ${optionsMarkup(command)}
  ${freeResponseMarkup(command)}
  <footer class="aiur-command-actions"><button type="submit">Record answer</button></footer>
</form>`;
}

function noticeMarkup(command) {
  const state = stateOf(command);

  if (state === 'expired') {
    return `<p class="aiur-command-notice" role="status">This Command is no longer answerable${command.reason ? ` (${escapeHtml(command.reason)})` : ''}.</p>`;
  }

  if (state === 'unavailable') {
    return '<p class="aiur-command-notice" role="status">Command state is unavailable right now.</p>';
  }

  if (state === 'error') {
    return `<p class="aiur-command-notice" role="alert">${escapeHtml(command.message ?? 'The Command could not be loaded.')}</p>`;
  }

  return '';
}

/**
 * Renders one Command component.
 *
 * @param {import('./contract.d.ts').CommandComponent} command
 * @param {{answerUrl?: string, method?: string}} [options]
 * @returns {string}
 */
export function renderCommand(command, options = {}) {
  const state = stateOf(command);
  const question = escapeHtml(command?.question ?? 'Command');
  const blocking = command?.blocking ? ' data-blocking="true"' : '';

  return `<article class="aiur-command" data-command-state="${state}"${reasonAttribute(command)}${blocking}>
  <header class="aiur-command-header">
    <span class="aiur-command-state">${escapeHtml(stateLabel(state))}</span>
  </header>
  <h3 class="aiur-command-question">${question}</h3>
  ${ticketLine(command)}
  ${recommendationLine(command)}
  ${noticeMarkup(command)}
  ${conflictMarkup(command)}
  ${pendingForm(command, options)}
  ${answerMarkup(command)}
  ${mediaMarkup(command)}
</article>`;
}

/**
 * Renders a Command collection, including the loading, empty and error states
 * that only exist for a list.
 *
 * @param {import('./contract.d.ts').CommandList} list
 * @param {{answerUrl?: string, method?: string}} [options]
 * @returns {string}
 */
export function renderList(list, options = {}) {
  const status = list?.status ?? 'error';

  if (status !== 'ready') {
    const copy = LIST_COPY[status] ?? LIST_COPY.error;
    const detail = status === 'error' && list?.error?.reason
      ? ` (${escapeHtml(list.error.reason)})`
      : '';

    return `<section class="aiur-commands" data-command-list-state="${escapeHtml(status)}"><p role="status">${copy}${detail}</p></section>`;
  }

  const commands = (list.commands ?? []).map((command) => renderCommand(command, options)).join('\n');

  return `<section class="aiur-commands" data-command-list-state="ready">\n${commands}\n</section>`;
}
