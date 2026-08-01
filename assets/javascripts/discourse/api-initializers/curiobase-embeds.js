import { apiInitializer } from "discourse/lib/api";

// Keep Curiobase media as OUR chrome. Discourse promotes bare youtube /
// archive / books URLs into aside.onebox; that fights the card stage and is
// what readers mean by "embeds becoming oneboxes".

function defuseOneboxes(root) {
  if (!root) {
    return;
  }

  root.querySelectorAll(".curiobase-card").forEach((card) => {
    // Undo any onebox class Discourse attached to links inside the card.
    card.querySelectorAll("a.onebox, a.inline-onebox, a.onebox-loading").forEach((a) => {
      a.classList.remove("onebox", "inline-onebox", "onebox-loading", "inline-onebox-loading");
    });

    // If a full onebox aside somehow landed inside the card, remove it —
    // the stage iframe / media-link is the source of truth.
    card.querySelectorAll("aside.onebox").forEach((box) => box.remove());
  });
}

export default apiInitializer((api) => {
  api.decorateCookedElement(
    (element) => {
      defuseOneboxes(element);
    },
    { id: "curiobase-defuse-oneboxes", onlyStream: false }
  );
});
