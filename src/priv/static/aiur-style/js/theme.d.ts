export type Theme = 'light' | 'dark';
export declare function getTheme(): Theme;
export declare function setTheme(theme: Theme, { persist }?: {
    persist?: boolean | undefined;
}): void;
export declare function onThemeChange(callback: (theme: Theme) => void): () => void;
export declare function initThemeToggle(button: HTMLButtonElement): {
    destroy: () => void;
};
