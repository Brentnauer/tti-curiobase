# Curiobase v1 — Production plan

**Status:** Strong conceptual v1; not yet “flip the switch on prod” without the checklist below.  
**Audience:** Operator (TTI) + whoever ships the Discourse plugin.  
**Dev target:** Discourse `tests-passed` / prod `latest` (currently `2026.8.0-latest.1`).  
**Repo:** `tti-curiobase` (plugin). Companion design notes may live in `discourse-curiobase`.

---

## 1. Thesis — what this is for

Time Travel Institute’s forum is already a 28-year archive of contested subjects and the works that engage them. Curiobase does **not** replace Discourse with a CMS. It makes a subset of topics into a **catalogue**:

| Concept | Meaning |
|---|---|
| **Work** | A film, book, game, series, video, or document you can experience |
| **Subject** | An idea, incident, claim, person, place, object, or org that works circle |
| **Pairing** | Created only by tagging a Work topic with a Subject slug from the Subject tag group |
| **Gravity** | 1–5 *centrality* (“how hard does this work pull on this idea”), **not** quality |
| **File** | The Subject’s own record topic is canonical; the tag page is navigation |
| **Bake** | Cards and scores live in `posts.cooked` so crawlers and no-JS readers see the same facts |

**Product promise:** Members and search engines can find *things* and *ideas*, see how they connect, and see what the membership thinks about those connections — without leaving the forum’s history, replies, and moderation tools.

**Non-goals for v1:** A separate CMS, mobile app, quality/review scores, institute-only “assessment” outside the vote, or inventing schema that blocks Discourse rebuilds without need.

---

## 2. Verdict — is this a good version 1?

**Yes, as a product and architecture.** The core model is coherent, Discourse-native, and test-backed (343 examples). The failure philosophy (“refuse loud in the composer; degrade quietly at render; `doctor` for silence”) matches a catalogue of contested claims.

**Not yet a complete production *release*** until ops, data durability, and a few remaining sharp edges are closed. Treat current code as **v1 candidate**: shippable behind a staged rollout, not as “enable and walk away.”

| Dimension | Grade | Notes |
|---|---|---|
| Concept / IA | A | Work × Subject × Gravity is clear and distinctive |
| Discourse fit | A− | Tags, cooked, wiki posts, PluginStore — right primitives |
| Correctness (happy path) | A− | Specs strong; recent tighten fixed tag rebake, validation patch, LD shape |
| Authoring UX | B+ | Fence + validator is real; still text-first, no composer UI |
| Ops / durability | B− | PluginStore OK to start; plan a table; doctor/rake required |
| SEO honesty | B+ | AggregateRating off by default + min voters; one primary pairing |
| Visual native-ness | B+ | Aside/onebox chrome; quieter badges/eyebrows; denser assoc rows |
| Docs / install | B+ | README + plan aligned to latest/`tests-passed` and guardrails |

---

## 3. System map — how the pieces fit

```
Author writes ```curiobase in first post
        │
        ├─► RecordValidator (composer) ── refuse bad facets / slug collisions
        │
        ▼
post_process_cooked → CardRenderer
        │
        ├─► cooked HTML (dek, poster/plate, gravity rows, associations…)
        ├─► topic custom fields (kind, slug claim, poster URL)
        └─► tag.description ← dek (Subject)

Subject tag on Work ──► pairing exists
        │
        ├─► gravity UI (client mount) → POST /curiobase/gravity → PluginStore
        └─► Subject association list (ranked) + ?curiobase= filter on tag page

Crawler head → JsonLd (Movie/Book/… + optional AggregateRating + about[])
```

**One authoring convention (v1 rule):** fenced `curiobase` is production. Legacy `[wrap=…]` remains *readable* until converted; do not author new wraps. Fixtures support specs and legacy resolution only.

---

## 4. Settings audit — what each switch is for

All under **Admin → Settings → Curiobase**. Defaults are intentional: safe dark, loud features opt-in.

| Setting | Default | Client? | Role in v1 | Production guidance |
|---|---|---|---|---|
| `curiobase_enabled` | off | yes | Master switch | Enable last, after vocabulary + a few records exist |
| `curiobase_subject_tag_group` | `Subjects` | no | Defines which tags create pairings | Create group + tags **before** enable; rename carefully |
| `curiobase_member_voting_enabled` | on | yes | Gravity exists only if on | Leave on for catalogue; off = no scores (by design) |
| `curiobase_min_trust_level` | 1 | yes | Who may cast; eligible votes weigh 1 | Raise if vote quality is poor |
| `curiobase_structured_ratings` | off | no | Emit `AggregateRating` stars | Leave off until you want the SERP experiment; entity markup still emits |
| `curiobase_structured_ratings_min_voters` | `5` | no | Floor on primary pairing | Only matters when structured ratings are on |
| `curiobase_buy_links_enabled` | off | no | “Find a copy” | Keep off until affiliate IDs and free IDs are real |
| `curiobase_amazon_tag` | blank | no | Amazon/AbeBooks | Blank = hidden |
| `curiobase_ebay_campaign` | blank | no | eBay search links | Blank = hidden |
| `curiobase_gog_tracking_prefix` | blank | no | Full Adtraction URL prefix | Blank = hidden; do not guess |

**Not plugin settings (but required ops):**

| Discourse setting / object | Why |
|---|---|
| Tag group `Subjects` (or whatever you set) | Vocabulary |
| First-post wiki / `edit_wiki_post_allowed_groups` | Shared community notes on the record (e.g. TL2+) |
| Theme | Visual polish; long-term CSS may move to a theme component |

**Settings gaps (nice-to-have, not blockers):**

- No plugin setting for wiki trust — use core Discourse wiki + group gates.
- No setting for rebake throttle / association `PER_BUCKET` — code constants; fine for v1.

---

## 5. What v1 must do (acceptance)

A release is “good v1” when all of the following are true on staging (then prod):

### Catalogue
- [ ] Staff can create a Work and a Subject via fenced blocks; composer rejects bad keys/values with named errors.
- [ ] Tagging a Work with a Subject tag creates a rateable pairing and shows a gravity row after rebake (including tag change **without** editing the post).
- [ ] Subject file association list ranks by gravity; filter chips work with and without JS; `?curiobase=` filters the tag topic list.
- [ ] Tag page banner + list scores appear for Subject vocabulary tags only.

### Gravity
- [ ] Logged-in users at min TL can rate 1–5; retract works; rate limit holds.
- [ ] Eligible votes weigh 1 each; suspended / under-floor users stop counting.
- [ ] Deleting a user removes their votes from PluginStore.
- [ ] Aggregates in the client response match what the next bake will show.

### Trust & crawlers
- [ ] Cards visible to Googlebot without JS; dek leads the snippet; badges do not.
- [ ] JSON-LD types correct; `sameAs` from identifiers; **at most one** `AggregateRating` on a Work URL (primary pairing); subjects as `about`.
- [ ] Affiliate links (if enabled) use `rel=nofollow sponsored` and disclosure.

### Ops
- [ ] `curiobase:doctor` clean (or known exceptions documented).
- [ ] No remaining production wraps, or a dated convert plan.
- [ ] Backup/restore story for votes understood (PluginStore rows under plugin name `curiobase`).
- [ ] Plugin pinned to a Discourse version compatible with prod `latest` / `tests-passed`.

---

## 6. Production readiness — gaps and decisions

### P0 — before public enable
1. **Staging dry-run** on a Discourse image matching prod channel (`latest` / tests-passed).
2. **Vocabulary** — Subject tag group populated; policy for who may create Subject tags.
3. **Convert legacy wraps** on any leftover topics (`curiobase:convert` / `doctor`).
4. ~~**README / install**~~ — done (latest/`tests-passed`, sync script, structured-ratings guardrails).
5. **Wiki edit groups** — set `edit_wiki_post_allowed_groups` (and first-post wiki) if community edits the record.
6. ~~**Smoke script**~~ — `bin/smoke-googlebot.py` (Work + Subject + tag). Leave `curiobase_structured_ratings` off unless intentionally testing stars.

### P1 — first month
7. **Vote durability plan** — stay on PluginStore for launch; schedule migration design to `curiobase_votes` (user_id, work_slug, subject_slug, value, timestamps) when volume or analytics need it.
8. **Theme component** — extract SCSS when the look settles so theme swaps don’t require plugin rebuilds.
9. **Monitor** — log greps for `[curiobase]`; Sidekiq failures on `curiobase_rebake`.
10. **Content SLA** — who owns `doctor` after bulk imports; dek length discipline (~155 for snippets).

### P2 — deliberate later
11. Composer assist (preview / field hints) — still optional; validator is enough for v1.
12. Richer JSON-LD (ClaimReview, etc.) only if Search Console shows entitlement.
13. Drop fixture/wrap read path entirely once prod is 100% fenced.
14. Association ranking cache if a Subject exceeds ~300 Works.

### Explicitly deferred (do not sneak into v1)
- Institute assessment / editorial score outside Standing.
- WordPress (or any second record source).
- Quality stars marketed as “reviews” in UI copy.
- Migrations “just because” without a PluginStore pain point.

---

## 7. Recommended production rollout

| Phase | Actions | Exit criteria |
|---|---|---|
| **0. Prep** | Staging = prod Discourse channel; clone plugin; create Subjects group | Doctor + specs green on staging |
| **1. Dark** | `curiobase_enabled` on; voting on; buy **off**; staff-only records | Cards bake; no member confusion |
| **2. Soft** | Invite TL2+ to rate a few pairings | Scores stable; no rebake storms |
| **3. Wiki** | First-post wiki + `edit_wiki_post_allowed_groups` if wanted | Shared notes without a second seeded post |
| **4. Commerce** | Enable buy links only with real IDs + free identifiers where true | Disclosure present; no empty shops |
| **5. Announce** | Point members at Subject files + how to rate | Support FAQ ready |

Rollback: set `curiobase_enabled` false. Cooked HTML may still contain old cards until rebake; votes remain in PluginStore. Disabling does not delete content.

---

## 8. Editorial workflow (operator)

1. Create Subject tag in the Subject group (slug = record slug).  
2. Create Subject topic with fenced block + plate image; title = display name.  
3. Create Work topic with fenced block + poster; tag with Subject slugs.  
4. Rate so the pairing isn’t empty (every eligible vote weighs 1).  
5. Optionally mark the first post a wiki for TL2+ community edits.  
6. Run `curiobase:doctor` after bulk work.

**Pairing rule to teach members:** tagging *is* the link. No tag → no gravity row, no association membership.

---

## 9. Engineering standards to keep

- **One door** for “what record is this”: `TopicRecord` + `Source`.  
- **One score path**: `Gravity.readings` → `Scores.blend` + `Standing`.  
- **Bake for truth, fetch for “mine”** — never personal data in shared `cooked`.  
- **Throttle rebakes** (`schedule_record_rebake!` / `schedule_pairing_rebake!`) — votes and tag changes; Work + Subject file, independently capped at one/minute each.
- **Live association scores** — Subject lists refresh via `GET /curiobase/readings` (batched PluginStore) + MessageBus `/curiobase/subject/:slug` after vote; baked HTML remains the crawler path.
- **Medium-aware embeds** — YouTube / Google Books / Archive **iframes** in `.cb-stage` (prefixes on `pretty_text_allowed_iframes`). **Posters/plates are attachment-only** — never auto-pull host covers. Prefer `google_books: VOLUME_ID` over ISBN probe. Series hubs list episodes via `series:` / `season` / `episode`.
- **Outside HTTP use `rebake_now!`** — plain `rebake!` in rake strips cards.
- Prefer Discourse plugin APIs (`validate`, events, serializers) over ad-hoc `class_eval`.

---

## 10. Test & verify matrix

| Layer | Command / check |
|---|---|
| Ruby | `LOAD_PLUGINS=1 bin/rspec plugins/tti-curiobase/spec` |
| JS | QUnit target `tti-curiobase` when browser available in container |
| Crawler | `User-Agent: Googlebot` on Work + Subject tag; confirm card text + ld+json |
| Doctor | `bin/rake curiobase:doctor` |
| Votes | Cast / retract / delete user; confirm store + display |
| Tags | Add Subject tag via UI (not only composer); confirm row after throttle window |

---

## 11. Open product questions (record decisions here)

| # | Question | Current lean |
|---|---|---|
| A | Keep AggregateRating despite “not quality”? | **Yes, optional** — off by default; on + min voters (default 5); one primary pairing; copy must not say “review score” |
| B | Who may create Subject tags? | Staff / trusted; not open TL0 |
| C | When to migrate votes off PluginStore? | When analytics, integrity, or scale hurt — design before pain |
| D | Theme component now or after visual pass? | Visual pass done in plugin; extract when TTI theme is chosen |
| E | Public catalogue size before buy links? | Prefer free identifiers first; shops when IDs are real |

---

## 12. Definition of done — “v1 production ready”

Ship when:

1. Staging matches prod Discourse channel and plugin specs pass.  
2. P0 checklist complete.  
3. At least one Work + one Subject file + one live pairing demonstrated under Googlebot.  
4. Rollout plan owner named; rollback understood.  
5. This document’s open questions A–E answered in writing (even if “defer”).

Until then: **excellent v1 candidate**, continue hardening via the checklist — do not treat “concept complete” as “prod complete.”

---

## 13. Suggested next engineering slices (priority)

1. ~~README sync + structured-ratings guardrails~~.  
2. ~~Local staging smoke (`curiobase:doctor` + `bin/smoke-googlebot.py`) + visual pass~~.  
3. Staging install on real TTI staging (if separate from local docker-dev).  
4. Convert any remaining wraps; freeze “no new wraps.”  
5. Vote table design doc (no migrate yet unless needed).  
6. Theme-component extraction after TTI theme sign-off.

---

*Last updated: 2026-08-01 — smoke script; aside-style cards; AggregateRating gated; README sync.*
