export interface CommandOptions {
    onCopy?: (text: string, kind: 'prompt' | 'command') => void;
    copiedMs?: number;
    labels?: {
        prompt?: string;
        command?: string;
    };
}
export declare function initCommand(el: HTMLElement, options?: CommandOptions): {
    destroy(): void;
};
