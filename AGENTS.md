# AGENTS.md — tti-curiobase

Context for AI assistants and humans shipping this Discourse plugin. Product docs stay in `README.md`; this file is operational memory.

## What this is

Discourse plugin that turns first-post fenced `curiobase` blocks into catalogue cards (Work / Subject), pairings via Subject tags, and gravity votes. Truth lives in `posts.raw` + PluginStore; **views** are baked into `posts.cooked` so crawlers and no-JS see the same facts.

## Hard invariants (do not regress)

1. **Dek first in cooked DOM** — Discourse meta description is taken from the start of cooked. Badges may look first via CSS `order`; never put badges/tables before the dek in the DOM.
2. **Bake for shared truth; fetch for “mine”** — never put personal vote state into shared cooked HTML.
3. **Outside HTTP, use `Curiobase.rebake_now!`** — bare `post.rebake!` can strip cards if ProcessPost never runs.
4. **Empty series hubs must not `add_child(nil)`** — cook aborts; keep hub card without an episodes section when there are no children.
5. **Posters / plates are attachment-only** — never auto-pull YouTube / Google Books / Archive covers into `.cb-poster`. Sources: dragged first-post image (`PostMedia`), explicit `poster.url`, else labelled empty tile. Stage embeds stay separate in `.cb-stage`.

## Media / embeds (current contract)

| Medium | Poster | Stage |
|---|---|---|
| film / series / game | Attachment or empty tile | YouTube iframe trailer (`youtube:`) |
| video | None (text head) | YouTube hero iframe, else Archive iframe |
| book | Attachment or empty tile | Google Books iframe (`google_books:`), else Archive |
| document | Attachment or empty tile | Archive iframe (`archive_org:`) |

- Iframe prefixes: `Curiobase::Embeds::ALLOWED_IFRAME_PREFIXES` → `pretty_text_allowed_iframes` in `plugin.rb`.
- Books URL shape: `https://books.google.com/books?id=VOLUME&pg=PR1&printsec=frontcover&output=embed`
- Archive URL shape: `https://archive.org/embed/{identifier}` (details slug, not full path).
- Prefer **`google_books: VOLUME_ID`**. ISBN probe is best-effort; **never cache HTTP failures / 429 as `"none"`** on the topic field (see `GoogleBooks`). Use `GoogleBooks.clear_cache!` to recover.
- Client `curiobase-embeds.js` only defuses Discourse oneboxes inside the card — no JS Books viewer.

## Dev environment notes

- Plugin mounts into Discourse docker-dev (container often `discourse_dev`; path `/src/plugins/tti-curiobase`).
- Specs: `LOAD_PLUGINS=1 bundle exec rspec plugins/tti-curiobase/spec` from Discourse root.
- Host reachability: `UNICORN_LISTENER=0.0.0.0:3000` when needed.
- After Ruby embed/renderer changes, if cooked looks stale or “regressing”, soft-reload Pitchfork/Unicorn workers, then `Curiobase.rebake_now!(post)`.
- Do not commit `tmp/`, `tmp_*`, or `node_modules/` (local Playwright experiments are scratch).

## Where to edit

| Concern | Primary files |
|---|---|
| Card bake | `app/services/curiobase/card_renderer.rb`, `subject_card.rb` |
| Embeds | `app/services/curiobase/embeds.rb`, `google_books.rb` |
| Styles | `assets/stylesheets/curiobase.scss` (`.cb-embed--gbooks`, `.cb-embed--archive`) |
| Onebox defuse | `assets/javascripts/.../curiobase-embeds.js` |
| Specs | `spec/services/embeds_spec.rb`, `work_media_series_spec.rb`, … |

## Do not

- Invent a second CMS or move record truth out of the fence.
- Auto-fill posters from host thumbs (`Result#thumb` may still exist for metadata — do not render it as poster).
- Commit debug runners, Playwright `node_modules`, or credentials.
- Push / force-push unless the human asked.
