// Only the same-origin parent shell can provide state or receive save requests.
let receive;
let pendingState;
let frame;
function flushState() {
  frame = undefined;
  const message = pendingState;
  pendingState = undefined;
  if (message !== undefined) receive?.(message);
}
window.registerDeskbarEditor = (callback) => { receive = callback; };
window.sendDeskbarEditor = (message) => {
  window.parent.postMessage({ channel: "deskbar-editor", message }, window.location.origin);
};
window.addEventListener("message", (event) => {
  if (event.source !== window.parent || event.origin !== window.location.origin ||
      event.data?.channel !== "deskbar-editor" || typeof event.data.message !== "string") return;
  // WebKit suspends rendering in hidden windows/iframes. Keep only the latest
  // snapshot until a frame can render, rather than repeatedly rebuilding Dart
  // state while its renderer cannot consume it. Save replies must stay prompt.
  let message;
  try { message = JSON.parse(event.data.message); } catch { return; }
  if (message.type === "state") {
    pendingState = event.data.message;
    frame ??= requestAnimationFrame(flushState);
  } else {
    receive?.(event.data.message);
  }
});
