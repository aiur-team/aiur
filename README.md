# @aiur/components

Shared CSS for Aiur and sibling projects. Import `theme.css` before the style modules you use:

```css
@import "@aiur/components/fonts.css";
@import "@aiur/components/theme.css";
@import "@aiur/components/marketing.css";
@import "@aiur/components/buttons.css";
```

The package exports `./fonts.css`, `./theme.css`, `./marketing.css`, and `./buttons.css` directly, so no JavaScript framework is required. `fonts.css` serves the bundled Bungee, Space Grotesk, and JetBrains Mono WOFF2 files; their SIL Open Font Licenses are included alongside them.

`theme.css` sets dark tokens on `:root` by default and overrides them on any `[data-theme="light"]` or `[data-theme="dark"]` element. Set `data-theme` on an application root to theme an embed independently of its host page. Only namespaced `--aiur-*` properties are assigned; the package does not set body colors or typography. Theme choice and persistence stay with the consuming application.

`marketing.css` provides `.aiur-topbar-link`, `.aiur-theme-toggle`, `.aiur-lockup-logo`, `.aiur-wordmark`, `.aiur-tagline`, and `.aiur-copy-control`. Place `.icon-sun` and `.icon-moon` SVGs inside the toggle. `buttons.css` provides `.aiur-action`, the dashboard-style primary action. Add `.aiur-actions` to a container to style its classless buttons as actions; buttons with a class keep their specialized styles. All controls accept local layout classes and use the theme tokens, including the shared font and size scale.
