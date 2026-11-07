/**
 * The Command component contract served by Aiur's ticket-scoped Commands API.
 *
 * One Command response becomes one `CommandComponent`. The same map is
 * rendered by Aiur's dashboard, so a host that follows this contract cannot
 * disagree with the dashboard about what state a Command is in.
 */

/** Every Command-level state a component can carry. */
export const COMMAND_STATES = [
  'pending',
  'answered',
  'revised',
  'expired',
  'unavailable',
  'conflict',
  'error',
];

/** Every list-level state a collection can carry. */
export const LIST_STATES = ['loading', 'empty', 'ready', 'unavailable', 'error'];

/** Every typed Command media kind a component can carry. */
export const MEDIA_KINDS = ['image', 'animated_image', 'video', 'audio'];

/**
 * @typedef {'pending' | 'answered' | 'revised' | 'expired' | 'unavailable' | 'conflict' | 'error'} CommandState
 */

/**
 * @typedef {object} CommandOption
 * @property {string} id
 * @property {string} label
 * @property {string | null} [description]
 * @property {string | null} [benefits]
 * @property {string | null} [drawbacks]
 * @property {string | null} [risk]
 * @property {CommandMedia[]} [media]
 */

/**
 * @typedef {object} CommandAnswer
 * @property {string | null} action_id
 * @property {number | null} decision_version
 * @property {string | null} selected_option_id
 * @property {string | null} custom_response
 * @property {string | null} rationale
 * @property {CommandOptionFeedback[]} [feedback] - present only when the answer carried feedback
 * @property {string | null} accepted_at
 */

/**
 * Per-option feedback sent with an answer; `verdict` is a closed set.
 *
 * @typedef {object} CommandOptionFeedback
 * @property {string} option_id
 * @property {'like' | 'dislike'} verdict
 * @property {string} [reason] - up to 500 characters
 */

/**
 * @typedef {'image' | 'animated_image' | 'video' | 'audio'} CommandMediaKind
 */

/**
 * A media locator as the contract publishes it.
 *
 * A `url` locator is an already-public `https:` URL. An `attachment` locator
 * names a file Aiur serves: the host reads it from
 * `GET /api/v1/commands/:decision_id/media/:attachment_id` with the same scoped
 * grant, so a server-local path never reaches the browser.
 *
 * @typedef {object} CommandMediaLocator
 * @property {'url' | 'attachment'} kind
 * @property {string} [value] - present for a `url` locator
 * @property {string} [attachment_id] - present for an `attachment` locator
 */

/**
 * A typed Command media item on a prompt or an option.
 *
 * @typedef {object} CommandMediaItem
 * @property {CommandMediaKind} kind
 * @property {string} mime_type
 * @property {CommandMediaLocator} locator
 * @property {string | null} [attachment_id]
 * @property {string | null} [alt_text]
 * @property {string | null} [caption]
 * @property {number | null} [byte_size]
 * @property {number | null} [width]
 * @property {number | null} [height]
 * @property {number | null} [duration_ms]
 * @property {CommandMediaLocator | null} [poster]
 */

/**
 * A pre-existing artifact reference carried alongside typed media.
 *
 * @typedef {object} CommandArtifactMedia
 * @property {'url' | 'path'} kind
 * @property {string} value
 */

/**
 * An entry in a Command's `media[]`: a typed item (it has a `locator`) or an
 * artifact reference (it has a bare `value`).
 *
 * @typedef {CommandMediaItem | CommandArtifactMedia} CommandMedia
 */

/**
 * @typedef {object} CommandComponent
 * @property {CommandState} state
 * @property {string | null} reason
 * @property {string | null} decision_id
 * @property {number | null} version
 * @property {string | null} question
 * @property {{identifier: string | null, title: string | null, url: string | null} | null} ticket
 * @property {boolean} blocking
 * @property {CommandOption[]} options
 * @property {{option_id: string, label: string} | null} recommendation
 * @property {{allowed: boolean, required: boolean}} free_response
 * @property {CommandAnswer | null} answer
 * @property {{kind: string, reason?: string, winner?: object | null} | null} conflict
 * @property {CommandMedia[]} media
 * @property {{answer: boolean, revise: boolean, enrich: boolean}} actions
 * @property {string | null} [source]
 * @property {string} [message]
 */

/**
 * @typedef {object} CommandList
 * @property {'loading' | 'empty' | 'ready' | 'unavailable' | 'error'} status
 * @property {CommandComponent[]} commands
 * @property {number} count
 * @property {{reason?: string} | null} error
 */

export {};
