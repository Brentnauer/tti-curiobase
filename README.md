# tti-curiobase

A Discourse plugin that turns topics into a catalogue.

Some topics are about a *thing* — a film, a book, a recovered document — and some are about an
*idea* the thing engages with. This plugin lets you say which is which, connect them, and let
members rate how strongly each one pulls on the other.

Records are written in the post itself, rendered into the page, and readable by search engines
without JavaScript. Nothing is moved: a topic keeps its replies, its links, and its history.

**Facts vs views:** pairings and votes are the truth; cards, lists, and structured data are derived
views. Gravity is always about a Work↔Subject *pair*, never a single collapsed “score for this
Work.”

| | |
|---|---|
| **Repo** | https://github.com/Brentnauer/tti-curiobase |
| **Version** | 0.1.0 |
| **License** | MIT |
| **Discourse** | `latest` / `tests-passed` (developed against `2026.8.x`); plugin header requires 3.2.0+ |

---

## Contents

1. [Concepts](#concepts)
2. [What it adds](#what-it-adds)
3. [How it works](#how-it-works)
4. [Requirements](#requirements)
5. [Install (production)](#install-production)
6. [Settings](#settings)
7. [Editorial workflow](#editorial-workflow)
8. [Writing a record](#writing-a-record)
9. [Connecting Work ↔ Subject](#connecting-work--subject)
10. [Gravity](#gravity)
11. [Media and embeds](#media-and-embeds)
12. [Series and episodes](#series-and-episodes)
13. [Association lists and filters](#association-lists-and-filters)
14. [Find a copy](#find-a-copy)
15. [Structured data](#structured-data)
16. [Community notes](#community-notes)
17. [Tag pages](#tag-pages)
18. [HTTP API](#http-api)
19. [Rake tasks](#rake-tasks)
20. [Development](#development)
21. [Operations and troubleshooting](#operations-and-troubleshooting)
22. [Further reading](#further-reading)

---

## Concepts

| Concept | Meaning |
|---|---|
| **Work** | Something you can read, watch, or play — film, series, book, game, video, document |
| **Subject** | What works circle — idea, incident, claim, person, place, object, org, or document |
| **Pairing** | Created by tagging a Work with a slug that has a Subject file |
| **Gravity** | 1–5 *centrality* (“how hard does this work pull on this idea”), **not** quality |
| **File** | The Subject’s own record topic is canonical; the tag page is navigation |
| **Bake** | Cards and scores live in `posts.cooked` so crawlers and no-JS readers see the same facts |
| **Slug** | Stable id for a record (`primer-2004`). One slug → one file, scoped across Work *and* Subject |

**Non-goals for v1:** a separate CMS, quality/review scores marketed as stars, an institute-only score outside the vote, or schema that blocks Discourse rebuilds without need.

---

## What it adds

**Work and Subject cards.** A fenced `curiobase` block in the first post becomes a card at the top
of the topic: dek, badges, facts, poster/plate, external links, gravity, and (when relevant)
embeds, episodes, and “Find a copy.”

**Gravity.** Members rate 1–5 how central a Subject is to a Work. Published anchors say what each
number means (fiction, nonfiction, or neutral wording — same scale).

**Association lists.** A Subject’s file shows Works that engage it, ranked by gravity, with a
**Works** chip by default, per-medium chips (top 10 within that medium), and a peer **Discussions**
chip (top 10 by likes). Chips are real links; a crawler that follows one gets a complete filtered
page. Scores refresh live for humans without waiting on rebake.

**Series hubs.** A Work with `medium: series` lists episode Works linked by `series: hub-slug`,
with season chips (when needed) and Air order / Most recommended sort.

**Community wiki.** Optional post 2 on every record topic for corrections beside the file.

**Find a copy.** Free sources first (Archive, libraries, Steam, streaming lookups), then affiliate
shops when configured. If a work is freely *held* (Archive/YouTube-as-the-work), shops are hidden.

**Structured data.** Works emit as `Movie`, `Book`, `VideoGame`, `TVSeries`, `VideoObject`, or
`CreativeWork`; Subjects as `Person`, `Organization`, `Event`, `Place`, `Claim`, and others, with
`sameAs`, image, ISBNs, credits, dates, and coordinates where present. Optional `AggregateRating`
is **off by default**.

---

## How it works

```
Author writes ```curiobase in first post
        │
        ├─► RecordValidator (composer) — refuse bad facets / slug collisions
        │
        ▼
post_process_cooked → CardRenderer
        │
        ├─► cooked HTML (dek, media, gravity, associations…)
        ├─► topic custom fields (kind, slug claim, poster URL, series parent)
        └─► tag.description ← dek (Subject)

Subject tag on Work ──► pairing exists
        │
        ├─► gravity UI → POST /curiobase/gravity → PluginStore
        ├─► Subject association list (ranked) + ?curiobase= on tag page
        └─► live readings via GET /curiobase/readings (+ MessageBus)

Crawler head → JsonLd (entity markup + optional AggregateRating)
```

**Authoring rule:** fenced `curiobase` is production. Legacy `[wrap=…]` remains *readable* until
converted; do not author new wraps. Fixtures support specs and legacy resolution only.

**Failure philosophy:** refuse loud in the composer; degrade quietly at render (log the reason);
`curiobase:doctor` for silence.

---

## Requirements

- Discourse **latest** / `tests-passed` (developed against `2026.8.x`)
- Plugin `required_version: 3.2.0+`

**Storage (v1):** votes live in `PluginStore` under plugin name `curiobase` — no migration required
to install. Topic custom fields cache kind, slug claim, poster URL, and series parent. A SQL vote
table is a planned later durability step with the same `(work, subject, user)` shape.

---

## Install (production)

Add to `containers/app.yml` and rebuild:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/Brentnauer/tti-curiobase.git
```

```bash
cd /var/discourse && ./launcher rebuild app
```

Then:

1. Author Subject files (`type: subject` / `slug: …`) — that slug becomes the pairing vocabulary.
2. Tag Works with those slugs.
3. Enable `curiobase_enabled` in **Admin → Settings → Curiobase** (last).

See [`docs/V1-PRODUCTION-PLAN.md`](docs/V1-PRODUCTION-PLAN.md) for staged rollout, P0 checklist, and
rollback notes.

**Rollback:** set `curiobase_enabled` false. Cooked HTML may still contain old cards until rebake;
votes remain in PluginStore. Disabling does not delete content.

---

## Settings

All under **Curiobase** in `/admin/site_settings`. Defaults are intentional: safe dark, loud
features opt-in.

| Setting | Default | Client | Role |
|---|---|---|---|
| `curiobase_enabled` | off | yes | Master switch. Enable last, after a few Subject files + Works exist. |
| `curiobase_min_trust_level` | `1` | yes | Minimum trust level to rate. Eligible votes all weigh the same. |
| `curiobase_member_voting_enabled` | on | yes | Gravity *is* the vote. Off = no scores at all (no editorial fallback). |
| `curiobase_structured_ratings` | off | no | Emit `AggregateRating` on Work pages (SEO experiment). Entity markup still emits either way. |
| `curiobase_structured_ratings_min_voters` | `5` | no | Floor on the primary pairing before stars emit. |
| `curiobase_buy_links_enabled` | off | no | “Find a copy” line. |
| `curiobase_amazon_tag` | — | no | Amazon Associates tag (also AbeBooks). Blank = hidden. |
| `curiobase_ebay_campaign` | — | no | eBay Partner Network campaign id. Blank = hidden. |
| `curiobase_gog_tracking_prefix` | — | no | Full Adtraction URL prefix (not an id). Blank = hidden. |

Each shop stays hidden until its id is set. The free half of “Find a copy” needs no configuration.

**Not plugin settings, but required ops:**

| Discourse setting / object | Why |
|---|---|
| Subject file topics (`type: subject`) | Pairing vocabulary — tags with a Subject file create gravity rows; others stay ordinary |
| First-post wiki / `edit_wiki_post_allowed_groups` | Community notes on the record itself (e.g. TL2+); not a plugin setting |
| `allowed_iframes` / CSP | YouTube / Books / Archive embeds (plugin also registers prefixes) |

When structured ratings are on, Google sees **one** `AggregateRating` per Work URL from the pairing
with the most voters (not an average across all Subject tags). Likes/recommends are never exported
as ratings.

---

## Editorial workflow

1. Create a Subject tag in the Subject group (slug = record slug).
2. Create the Subject topic: fenced block + optional plate image; title = display name.
3. Create Work topics: fenced block + optional poster; tag with Subject slugs.
4. Rate the pairing so the list isn’t empty.
5. Optionally make the first post a wiki (Discourse) so TL2+ can refine the record.
6. Run `curiobase:doctor` after any bulk change.

**Teach members:** tagging *is* the link. No Subject tag → no gravity row, no association membership.

---

## Writing a record

Put a fenced `curiobase` block at the top of the first post. The topic title is the record’s
display title.

**This is the only production authoring format.** Legacy `[wrap=…]` markers remain readable until
converted; do not add new wraps. A fence that fails to render still shows as a visible code block —
the data stays on the page. A wrap that fails renders as nothing.

Unknown keys and values outside the allowlists are rejected in the composer, with the offending
value and the allowed set named in the error.

### Work example

````markdown
```curiobase
type: work
slug: primer-2004
medium: film
mode: fiction
year: 2004
creator: Shane Carruth
runtime: 77 min
imdb: tt0390384
dek: Two engineers building something in a garage discover their device leaves
  objects with a repeating temporal anomaly.
```
````

### Subject example

````markdown
```curiobase
type: subject
slug: rendlesham-forest
kind: incident
domain: contact
status: contested
period: 1980s
evidence: firsthand-account, physical-trace
began: 1980-12-26
where: Rendlesham Forest, Suffolk
dek: Three nights of lights near two USAF bases in December 1980.
```
````

Drag an image into the post: it becomes the **poster** (Works, 2:3) or the **plate** (Subjects,
3:2). Subjects may set `image_credit` for the plate caption. For `medium: video`, the dragged
image is still claimed (Subject list thumbs + lifted out of the body) but is **not** shown in
the card head — the stage player is the media.

### Required fields

| Type | Required |
|---|---|
| Work | `slug`, `medium`, `dek` |
| Subject | `slug`, `kind`, `domain`, `dek` |

`slug` must match `[a-z0-9][a-z0-9-]*`. Slugs are unique across Work *and* Subject — one namespace.

`dek` max length is **200** characters (composer-enforced). Keep it near **~155** when you care
about search snippets: the dek leads the cooked HTML so it wins Discourse’s meta description.

### Vocabulary

| Field | Allowed values |
|---|---|
| `type` | `work` · `subject` |
| `medium` | `film` `series` `book` `game` `video` `document` |
| `mode` | `fiction` · `nonfiction` |
| `kind` | `idea` `incident` `claim` `person` `place` `object` `org` `document` |
| `domain` | `time` `reality` `consciousness` `contact` `phenomena` `hidden-history` `esoterica` `science` `control` `futures` |
| `status` | `open` `contested` `explained` `debunked` `hoax-admitted` `unfalsifiable` |
| `period` | `ancient` `pre-1950` `1950s` … `2020s` (list; comma-separated) |
| `evidence` | `primary-source` `firsthand-account` `secondhand-account` `physical-trace` `documentary-record` `no-evidence` (list) |

### Work fields

| Field | Notes |
|---|---|
| `year` | 3–4 digits |
| `creator` | Free text |
| `runtime` | Free text (e.g. `77 min`, `3 seasons`) |
| `series` | Hub Work slug (episode → parent) |
| `season` / `episode` | Integers |

### Subject→Subject edges

Typed pointers between Subjects. One fence key per verb; comma-separated slugs.
Targets must have a Subject file. Flat `refs:` stays the untyped escape hatch.

```curiobase
explains: orfordness-lighthouse
contradicts: official-denial
precedes: halt-memo
involves: charles-halt
refs: bentwaters
```

| Key | Meaning |
|---|---|
| `explains` | Competing / sceptical account of this file |
| `contradicts` | Evidence or account that cuts against it |
| `precedes` | Earlier event in a chain (forward only) |
| `part_of` | Mereology (incident inside a flap, …) |
| `involves` | Person, org, or object that participates |
| `refs` | Related (untyped) |

Authorship is outbound only — writing A→B does not edit B's fence. At bake, each
edge is stored as a `curiobase_edge` custom-field row on A (`verb:slug`). B's
full card shows an inbound attribution block ("Other files point here") for
`explains` / `contradicts`, phrased as "A — explains this." Cap 12 edges per
record. Do not use `same_as` — merge topics or put aliases in `also_known_as`.
Work→Work relations are not these keys.

**Ops / consistency.** Inbound cooked HTML is eventually consistent: edge
changes (and source topic trash/recover) enqueue a debounced target rebake
(`schedule_subject_file_rebake!`, 60s redis gate, 5s delay). Manual
`Curiobase.rebake_now!(post)` is immediate. After enabling this feature on an
existing catalogue, run `bin/rake curiobase:rebake` (or rebake Subjects that
are inbound targets) so attribution appears without waiting for an edit.
`curiobase:doctor` flags edges whose target has no Subject file.

### Subject facts by kind

Facts are flat key-value lines (no nested groups). Use the ones that fit the kind:

| Kind | Facts |
|---|---|
| `idea` | — |
| `incident` | `began` `ended` `where` `witnesses` `outcome` |
| `claim` | `asserted` `claimant` |
| `person` | `born` `died` `active` `nationality` `known_for` |
| `place` | `country` `active` |
| `object` | `object_kind` `provenance` `whereabouts` |
| `org` | `founded` `dissolved` `org_kind` `jurisdiction` |
| `document` | `source_site` `section` `transmitted` `captured` `operator` |

Also useful on Subjects: `also_known_as`, `coords`, `landing_url`, `image_credit`.

### Identifiers (external)

Written as flat keys on the fence; stored under `external` at render time.

| Key | Used for |
|---|---|
| `imdb` | Link + `sameAs` |
| `tmdb` | Link + `sameAs` |
| `isbn` | Open Library link, WorldCat, Google Books probe + `sameAs` |
| `igdb` | Link + `sameAs` |
| `youtube` | Embed / watch link + `sameAs` |
| `archive_org` | Archive link card / free hold + `sameAs` |
| `wikipedia` | Link + `sameAs` (strongest reconciliation signal) |
| `google_books` | Explicit volume id (optional; ISBN probe can find one) |
| `asin` | Affiliate “Find a copy” only — **never** in `sameAs` |

Body text below the fence is ordinary Discourse markdown (synopsis, discussion, etc.).

---

## Connecting Work ↔ Subject

Tag the Work’s topic with the Subject’s slug (must have a Subject file for that slug). That tag *is* the
pairing: it creates the gravity row, association membership, and rateability.

- Adding or removing a Subject tag schedules a throttled rebake of the Work card and the Subject
  file (about one rebake per topic per minute).
- Ordinary tags outside the Subject group create no rating row.
- Prefer tagging via the topic UI; tag changes without editing the first post still schedule rebake.

---

## Gravity

Gravity answers: *how central is this Subject to this Work?* It is not a quality score.

### Anchors (1–5)

Three label sets, one scale — a 5 is a 5 in any of them; mixed association lists still rank.

| | Fiction (structural) | Nonfiction (dossier) | Neutral (gravitational / mixed lists) |
|---|---|---|
| 1 | a mention | a mention | a mention |
| 2 | set dressing | secondhand | peripheral |
| 3 | plays fair | a briefing | in its orbit |
| 4 | load-bearing | an investigation | bound to it |
| 5 | made of it | part of the record | inseparable |

A Work card uses its own `mode`. A Subject association list uses fiction or nonfiction only when
every listed Work agrees; otherwise neutral.

### Who counts

Every eligible member’s vote weighs **1**. Eligibility is `trust_level ≥ curiobase_min_trust_level`,
active, and not suspended/silenced. Under-floor votes can still be stored; they start counting when
the account qualifies. Suspended users stop counting. Deleting a user removes their PluginStore votes.

### Client behaviour

- Marks mount on baked gravity rows; “Your take” / unrated chrome appears after the live fetch.
- Clicking your own mark again retracts the vote.
- After a vote, Subject association rows update scores and reorder Works live (discussions stay
  after Works). Baked HTML remains the crawler path; a throttled rebake follows.
- **Members disagree** is computed from the vote distribution (real weight on both 1–2 and 4–5).
  Work cards name it beside the bar; association rows get a dotted gravity mark + tooltip. When
  staff `status` is `explained` / `debunked` / `hoax-admitted` but any pairing still splits,
  the Subject list shows a quiet note — and `curiobase:doctor` can flag the same tension.

### Limits

- Rate limit: 30 casts per user per hour (retract is not limited).
- Trust check applies on cast, not on retract.

---

## Media and embeds

Every playable / linkable embed lands in `.cb-stage` below the identity head (poster + dek +
badges), above gravity — Discord-style: identity, then media, then the rest.

| Medium | Poster column | Stage |
|---|---|---|
| `film` / `series` / `game` | Author attachment only (else label tile) | YouTube **iframe** trailer when `youtube:` is set |
| `video` | No head column (text head). Drag a YouTube thumbnail into the post — claimed for Subject list thumbs only, not shown in the card head | YouTube **iframe** (the work itself), else Archive iframe |
| `book` | Author attachment only (else label tile) | Google Books **iframe** when `google_books:` is set; Archive iframe fallback |
| `document` | Author attachment only (else label tile) | Archive.org **iframe** (`/embed/{id}`) when `archive_org:` is set |

**Posters / plates are never auto-pulled** from YouTube, Google Books, or Archive. Drag an image into the first post (or set an authored `poster` URL on the record). Until then the head shows a labelled empty tile.

**Books:** set `google_books: VOLUME_ID` from the Books URL. ISBN probe is best-effort only (API quota).

**Archive:** set `archive_org:` to the `/details/` identifier (e.g. `chemotaxonomiede05hegn`). Uses Archive’s official share embed. Borrow-only items may show Archive’s borrow UI inside the frame.

YouTube / Books / Archive prefixes are registered via `pretty_text_allowed_iframes`.

---

## Series and episodes

1. Create a hub Work with `medium: series` and its own `slug`.
2. Create episode Works (`medium: video` typically) with `series: hub-slug` plus optional
   `season:` / `episode:`.
3. Rebake the hub (automatic on episode bake / scheduled rebake). The hub lists children ordered by
   season → episode → title.

**Hub tools (client):**

- Season chips when more than one season is present (`All` + each season)
- Sort: **Air order** (default) or **Most recommended** (likes)
- Chip `href`s point at `#cb-episodes-{slug}` so no-JS clicks stay put

Association rows for episodes show an eyebrow like `Series · S1E12`. Rate gravity on the episode
(or the hub) by tagging Subjects as usual — gravity is always Work↔Subject.

An empty series hub still bakes a full card; the episodes section appears only when children exist.

---

## Association lists and filters

On a Subject **file** (full card):

- **Works** chip (default): top 10 Works by gravity → OP likes → posts
- Medium chips: top 10 Works of that medium (membership, not “overall then hide”)
- **Discussions** chip: top 10 threads by topic likes, then `bumped_at` — peer ladder, not mixed into Works
- No blended **All** chip (avoids one numbered list for two incomparable rankings)
- Chips link to the tag page (`Works` unfiltered; others `?curiobase=<medium|discussion>`) and filter in-card with JS
- Live score refresh via `GET /curiobase/readings?subject=…&works=…`
- After votes, MessageBus + assoc-live JS update scores and Work order without full page reload

On the **tag page**:

- Banner HTML travels with the topic-list payload (no flash of empty list)
- `?curiobase=` filters Discourse’s own topic list in SQL (`film`, `book`, …, `discussion`)
- Only tags with a Subject file get catalogue pairing behaviour (gravity, associations)
- Those tags render with class `cb-subject-tag` so they read differently from ordinary tags

---

## Find a copy

Gate: `curiobase_buy_links_enabled`. Free sources need no affiliate config.

**Free first** (examples; medium-scoped):

- Internet Archive when `archive_org` is set — *holds* the work → hides shops
- Watch on YouTube when `medium: video` and `youtube` is set — *holds* → hides shops
- WorldCat / library lookups for books and documents
- Steam / streaming search helpers where relevant

**Shops** (only with ids configured; `rel=nofollow sponsored` + disclosure):

- Amazon / AbeBooks (`curiobase_amazon_tag`; ASIN or title search)
- eBay search (`curiobase_ebay_campaign`) — searches, never listings
- GOG (`curiobase_gog_tracking_prefix` — full Adtraction prefix)

`document` is never offered for sale. A film’s YouTube trailer does **not** suppress shops (trailer
≠ the work).

---

## Structured data

Emitted into the crawler head via `server:before-head-close-crawler`.

- Work types from `medium`; Subject types from `kind`
- `sameAs` from the identifiers registry (not `asin`)
- Subjects appear as `about` on Work pages where tagged
- Optional `AggregateRating`: off by default; when on, **one** primary pairing (most voters) and
  only if voter count ≥ `curiobase_structured_ratings_min_voters`

Smoke with Googlebot UA or `bin/smoke-googlebot.py`.

---

## Community notes

Curiobase does **not** seed a separate wiki post. Use Discourse’s own tools on the record topic:

- Mark the **first post** as a wiki when you want shared edits
- Set `edit_wiki_post_allowed_groups` (e.g. trust_level_2) for who may edit
- Keep the fenced `curiobase` block intact — that is still the machine-readable record

---

## Tag pages

| Surface | Behaviour |
|---|---|
| Banner | Subject dek + chips + link to the file topic |
| Topic list | Optional `?curiobase=` medium / discussion filter |
| Scores | Live where the list serializer carries them |

The Subject **file** topic (slug claim) is canonical. The tag page is how you browse the pairing
space.

---

## HTTP API

Routes append into Discourse’s own route set (not a mounted engine).

### Gravity

| Method | Path | Body / query | Notes |
|---|---|---|---|
| `GET` | `/curiobase/gravity.json` | `topic_id`, `subject` | Returns `{ mine }` for the current user |
| `POST` | `/curiobase/gravity.json` | `topic_id`, `subject`, `value` (1–5) | Cast / change |
| `DELETE` | `/curiobase/gravity.json` | `topic_id`, `subject` | Retract |

The client does not name the Work id — the server reads it from the topic’s record and verifies the
Subject tag is on the topic and in the vocabulary. Requires login; plugin + voting must be enabled.

### Readings (live association scores)

```
GET /curiobase/readings.json?subject=john-titor&works=primer-2004,timecrimes-2007
→ { "subject": "…", "readings": { "primer-2004": { "display": 3.0, "voter_count": 1 }, … } }
```

Comma-separated `works` (repeated `works=` is unreliable under Rack). Cap matches the association
list size. Public; used to refresh baked Subject lists without re-ranking.

---

## Rake tasks

Run inside the Discourse app with plugins loaded, e.g.:

```bash
cd /var/discourse && ./launcher enter app
LOAD_PLUGINS=1 bundle exec rake curiobase:doctor
```

| Task | Purpose |
|---|---|
| `curiobase:doctor` | Health check — stale claims, slug collisions, missing medium/kind cache, quiet breakage |
| `curiobase:rebake` | Re-render every record. No revisions, no bumps. Uses the full cook path. |
| `curiobase:convert[only]` | Move a legacy `[wrap]` into a fenced block. Refuses rather than dropping a field |
| `curiobase:repair[write]` | Restore fields an earlier conversion dropped (`write` to persist) |
| `curiobase:unclaim` | Release stale slug claims |
| `curiobase:repoint` | Rewrite numeric work wraps to slugs (legacy) |
| `curiobase:seed` | Local demo topics (fenced blocks); idempotent |

Run `curiobase:doctor` after any bulk change. Outside a request, always prefer `Curiobase.rebake_now!`
over bare `post.rebake!` — plain `rebake!` cooks markdown then enqueues ProcessPost; if the process
exits first, cards are stripped and never put back.

---

## Development

Local Discourse docker-dev should track **`tests-passed`** (prod `latest`). From WSL:

```bash
bin/sync-discourse-latest   # or ~/sync-discourse-latest
```

That pulls Discourse, remounts this plugin from your checkout, migrates, and starts `bin/dev`.
Ports: app `:3000`, MailHog `:8025`, etc. (see the script).

```bash
# inside the Discourse container / via d/rspec
LOAD_PLUGINS=1 bin/rspec plugins/tti-curiobase/spec
bin/qunit --standalone --target tti-curiobase   # needs a browser in the container

# Googlebot / crawler smoke (host; Discourse on :3000)
python3 bin/smoke-googlebot.py http://127.0.0.1:3000
```

### Reload expectations

| Change | What to do |
|---|---|
| Renderer / services under `app/` | Usually hot-reload; **rebake** topics to see cooked HTML. If cooked regresses to old shapes, soft-reload Pitchfork/Unicorn (stale workers) |
| `lib/` required from `plugin.rb`, `config/settings.yml` | Restart the server |
| SCSS | Asset pipeline recompile + hard-refresh (stylesheet hash can stick) |
| Client JS under `api-initializers/` | Refresh; some paths need a full rebuild in production |

Agent / maintainer notes for this repo live in [`AGENTS.md`](AGENTS.md) (also mirrored under `.cursor/rules/`).

### Layout (where things live)

| Path | Role |
|---|---|
| `plugin.rb` | Boot: hooks, routes, iframe allowlist, serializers |
| `app/services/curiobase/` | CardRenderer, SubjectCard, Gravity, Embeds, BuyLinks, JsonLd, … |
| `app/controllers/curiobase/` | Gravity + Readings API |
| `lib/curiobase/` | Source, VoteStore, Standing, RecordTopic, rebake helpers, Markup |
| `assets/javascripts/.../api-initializers/` | Gravity UI, filters, embeds, assoc-live, episodes |
| `assets/stylesheets/curiobase.scss` | Card chrome |
| `config/settings.yml` | Site settings |
| `lib/tasks/curiobase.rake` | Ops tasks |
| `fixtures/` | Spec / legacy resolution data |
| `spec/` | RSpec (plugin suite) |
| `test/javascripts/` | QUnit acceptance |

---

## Operations and troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Empty wrap / no card | Render exception (logged as `[curiobase] render failed`) | Check logs; fix data; `rebake_now!` |
| Fence visible as code | Plugin off, or record invalid / not first post | Enable plugin; fix fence; ensure first post |
| No gravity row | Subject tag missing or no Subject file for that slug | Author a Subject file, then tag the Work |
| Scores stale after vote | Throttle / Sidekiq | Wait ≤60s; check `Jobs::CuriobaseRebake`; live UI should still update |
| Trailer / Books / Archive missing | Bad id, or iframe stripped | Valid `youtube` / `google_books` / `archive_org`; allowlist / CSP; soft-reload app after Ruby embed changes |
| Books stage empty | No volume id; ISBN probe 429 / blocked | Prefer `google_books: VOLUME_ID`; `GoogleBooks.clear_cache!` if a bad `"none"` stuck |
| Empty poster / plate | No dragged image and no `poster.url` | Expected — attach an image in the first post (hosts never auto-fill covers) |
| Wrong search snippet | Badges before dek in DOM | Must not regress — dek first; badges use CSS `order` |
| Routes 404 | Routes not reloaded after boot change | Restart; `reload_routes!` is in `plugin.rb` |
| Doctor noise after convert | Stale claims / wraps | `unclaim` / `convert` / `repair` |

**Monitor:** log lines tagged `[curiobase]`; Sidekiq failures on `curiobase_rebake`.

**Backup:** PluginStore rows for plugin `curiobase` (votes); topic custom fields for claims/posters;
record truth is the fenced block in `posts.raw`.

---

## Further reading

- [`docs/V1-PRODUCTION-PLAN.md`](docs/V1-PRODUCTION-PLAN.md) — rollout phases, acceptance checklist,
  durability plan, open product questions
- Discourse Admin → Settings → Curiobase — live setting descriptions (from
  `config/locales/server.en.yml`)

## License

MIT
