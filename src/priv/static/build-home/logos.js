// Payload keys must never resolve Object.prototype members as logos.
export const LOGOS = Object.freeze(Object.assign(Object.create(null), {
  claude: Object.freeze({ src: "/provider-assets/claude-symbol.svg", fill: false }),
  codex: Object.freeze({ src: "/provider-assets/codex-color.svg", fill: false }),
  deepseek: Object.freeze({ src: "/build-home/logos/deepseek-logo.png", fill: true }),
  kimi: Object.freeze({ src: "/build-home/logos/kimi-logo.png", fill: true })
}));
