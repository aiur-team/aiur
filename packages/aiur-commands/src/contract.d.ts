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
 */

/**
 * @typedef {object} CommandAnswer
 * @property {string | null} action_id
 * @property {number | null} decision_version
 * @property {string | null} selected_option_id
 * @property {string | null} custom_response
 * @property {string | null} rationale
 * @property {string | null} accepted_at
 */

/**
 * @typedef {object} CommandMedia
 * @property {string} kind - `url` or `path`
 * @property {string} value
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
