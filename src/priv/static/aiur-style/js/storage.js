// Storage may be blocked even when accessing the localStorage property.
export function readStorage(key) {
    try {
        return localStorage.getItem(key);
    }
    catch {
        return null;
    }
}
export function writeStorage(key, value) {
    try {
        localStorage.setItem(key, value);
    }
    catch { /* Keep the in-memory choice. */ }
}
