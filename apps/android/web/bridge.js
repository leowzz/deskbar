// Only the same-origin parent shell can provide state or receive save requests.
let receive;
window.registerDeskbarEditor = (callback) => { receive = callback; };
window.sendDeskbarEditor = (message) => {
  window.parent.postMessage({ channel: "deskbar-editor", message }, window.location.origin);
};
window.addEventListener("message", (event) => {
  if (event.source !== window.parent || event.origin !== window.location.origin ||
      event.data?.channel !== "deskbar-editor" || typeof event.data.message !== "string") return;
  receive?.(event.data.message);
});
