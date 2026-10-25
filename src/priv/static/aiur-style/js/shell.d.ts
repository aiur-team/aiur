export interface ShellNavOptions {
    storageKey?: string;
    onToggle?: (collapsed: boolean) => void;
}
/** Enhance a shell; return a disposer for hosts that unmount their page. */
export declare function initShellNav(shell: HTMLElement, { storageKey, onToggle }?: ShellNavOptions): () => void;
