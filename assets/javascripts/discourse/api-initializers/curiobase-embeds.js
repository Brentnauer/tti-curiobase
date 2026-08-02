import { apiInitializer } from "discourse/lib/api";

// Keep Curiobase media as OUR chrome. Discourse promotes bare youtube /
// archive / books URLs into aside.onebox; that fights the card stage and is
// what readers mean by "embeds becoming oneboxes".
//
// Google Books is a baked iframe (same path as YouTube) — no client viewer.

function defuseOneboxes(root) {
  if (!root) {
    return;
  }

  root.querySelectorAll(".curiobase-card").forEach((card) => {
    card.querySelectorAll("a.onebox, a.inline-onebox, a.onebox-loading").forEach((a) => {
      a.classList.remove("onebox", "inline-onebox", "onebox-loading", "inline-onebox-loading");
    });
    card.querySelectorAll("aside.onebox").forEach((box) => box.remove());
  });
}

export default apiInitializer((api) => {
  api.decorateCookedElement(
    (element) => {
      defuseOneboxes(element);
    },
    { id: "curiobase-embeds", onlyStream: false }
  );
});
