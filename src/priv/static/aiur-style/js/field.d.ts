export interface Obstacle {
    cx: number;
    cy: number;
    hx: number;
    hy: number;
    r: number;
}
export interface FlowFieldOptions {
    host?: HTMLElement;
    keepouts?: string;
    hug?: string;
    angleDeg?: number;
    spacing?: number;
    step?: number;
    gap?: number;
    fade?: number;
    logoSelector?: string;
    entranceMs?: number;
}
export declare function createFlowField(canvas: HTMLCanvasElement, opts?: FlowFieldOptions): {
    redraw: () => void;
    rebuild: () => void;
    destroy: () => void;
    debug: () => {
        obstacles: Obstacle[];
    };
};
