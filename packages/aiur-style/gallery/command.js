import { setTheme } from '../dist/js/index.js';
const theme = new URLSearchParams(location.search).get('theme');
if (theme === 'light' || theme === 'dark') setTheme(theme);
