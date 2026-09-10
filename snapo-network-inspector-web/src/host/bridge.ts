interface WebKitMessageHandler {
  postMessage(message: { command: string; payload?: unknown }): Promise<unknown>;
}

function webKitMessageHandler(): WebKitMessageHandler | null {
  const hostWindow = window as Window & {
    webkit?: { messageHandlers?: { snapoNetwork?: WebKitMessageHandler } };
  };
  return hostWindow.webkit?.messageHandlers?.snapoNetwork ?? null;
}

export async function invokeNative<T>(command: string, payload?: unknown): Promise<T> {
  return (await requireNativeBridge().postMessage({ command, payload })) as T;
}

export function requireNativeBridge(): WebKitMessageHandler {
  const handler = webKitMessageHandler();
  if (handler == null) throw new Error("Open this inspector in the Snap-O macOS app.");
  return handler;
}

export function listenWebKitEvent<T>(eventName: string, callback: (payload: T) => void): () => void {
  const listener = (event: Event) => callback((event as CustomEvent<T>).detail);
  window.addEventListener(`snapo:${eventName}`, listener);
  return () => window.removeEventListener(`snapo:${eventName}`, listener);
}
