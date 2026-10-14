export interface ScrollCueOptions {
    hideAfter?: number;
    hideWhen?: () => boolean;
}
export declare function initScrollCue(el: HTMLElement, { hideAfter, hideWhen }?: ScrollCueOptions): {
    destroy(): void;
};
