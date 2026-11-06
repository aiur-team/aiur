// One import for a plain page: the renderers, the parser and the element.
// Importing also defines <aiur-build-order> when the page has a DOM.
export {
  BUILD_ORDER_CONTRACT,
  BUILD_ORDER_VERSION,
  ELEMENT_NAME,
  EDGE_TYPES,
  EDGE_LABELS,
  EDGE_NOTES,
} from './contract.js';
export { parseBuildOrder, buildOrderError } from './parse.js';
export { renderReview } from './review.js';
export { renderGraph } from './graph.js';
export { AiurBuildOrderElement, registerAiurBuildOrder } from './element.js';
export { STYLES, STYLESHEET_NAME } from './styles.js';
