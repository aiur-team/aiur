/**
 * Visual testing utilities and masking configuration.
 *
 * Provides mask configuration for time-based elements that should not trigger
 * snapshot comparison failures due to dynamic content (timestamps, durations, usage meters).
 */

/**
 * Returns the mask configuration for toHaveScreenshot().
 *
 * Masks are applied during both baseline capture and comparison, so time-based
 * content updates do not cause spurious failures. Real CSS changes are still detected.
 *
 * @returns {Array<{selector: string, reason: string}>} Array of mask objects
 */
export const getMaskConfig = () => [
  {
    selector: '[data-testid="relative-time"]',
    reason: 'Relative timestamp varies by screenshot time'
  },
  {
    selector: '[data-testid="duration-badge"]',
    reason: 'Live duration updates'
  },
  {
    selector: '.usage-meter-value',
    reason: 'Real-time usage number that updates constantly'
  },
  {
    selector: '[data-testid="agent-uptime"]',
    reason: 'Agent uptime duration updates every second'
  },
  {
    selector: '.freshness-indicator',
    reason: 'Freshness/age indicator updates in real time'
  }
]
