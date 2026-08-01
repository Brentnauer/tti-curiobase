# tti-curiobase

A Discourse plugin that turns topics into a catalogue.

Some topics are about a *thing* — a film, a book, a recovered document — and some are about an
*idea* the thing engages with. This plugin lets you say which is which, connect them, and let
members rate how strongly each one pulls on the other.

Records are written in the post itself, rendered into the page, and readable by search engines
without JavaScript. Nothing is moved: a topic keeps its replies, its links and its history.

**Facts vs views:** pairings and votes are the truth; cards, lists, and structured data are derived
views. Gravity is always about a Work↔Subject *pair*, never a single collapsed “score for this
Work.”

---

## What it adds

**Work and Subject records.** A Work is something you can read, watch or play. A Subject is what
works circle — an idea, incident, claim, person, place, object or organisation. Each gets a card at
the top of its own topic.

**Gravity.** Members rate 1–5 how central a Subject is to a Work. This is not a quality score, and
the published anchors say so: *mentions it · set dressing · takes it seriously · builds on it ·
cannot exist without it.*

**Association lists.** A Subject's topic shows the works that engage it, ranked, with filter chips
per medium. The chips are real links, so a crawler follows them to a complete filtered page.

**A community wiki** as post 2 of every record (when enabled), so corrections live beside the file.

**"Find a copy."** Free sources first — Internet Archive, libraries, Steam, streaming lookups —
then affiliate links, marked as paid. If a work is freely available, the shops are not shown.

**Structured data.** Works are emitted as `Movie`, `Book`, `VideoGame`, `TVSeries`, `VideoObject`
or `CreativeWork`; Subjects as `Person`, `Organization`, `Event`, `Place`, `Claim` and others, with
`sameAs`, `image`, ISBNs, credits, dates and coordinates where the record has them. Optional
`AggregateRating` stars are **off by default** (see settings) — entity markup stays either way.

---

## Requirements

Discourse **latest** / `tests-passed` (developed against `2026.8.x`). Plugin header requires 3.2.0+.

Votes live in `PluginStore` for v1 (no migration required to install). Topic custom fields cache
kind, slug claim, and poster URL. A SQL vote table is a planned later durability step — same
`(work, subject, user)` shape.

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

Create the Subject tag group, then enable `curiobase_enabled` in **Admin → Settings → Curiobase**.
See [`docs/V1-PRODUCTION-PLAN.md`](docs/V1-PRODUCTION-PLAN.md) for staged rollout.

---

## Settings

All under **Curiobase** in `/admin/site_settings`.

| Setting | Default | |
|---|---|---|
| `curiobase_enabled` | off | Master switch. |
| `curiobase_subject_tag_group` | `Subjects` | The tag group holding the Subject vocabulary. A tag outside it is an ordinary tag. |
| `curiobase_min_trust_level` | `1` | Minimum trust level to rate. |
| `curiobase_member_voting_enabled` | on | Gravity *is* the vote. Off means no score at all, not a fallback. |
| `curiobase_supporter_group` | — | Group picker. Members get +1 vote weight, capped at 5. |
| `curiobase_annotation_enabled` | off | Community wiki at post 2. **New** records auto-seed when on; run `curiobase:annotate` once to backfill history. Set Discourse `edit_wiki_post_allowed_groups` before enabling. |
| `curiobase_structured_ratings` | off | Emit `AggregateRating` on Work pages (SEO experiment). Off = entity markup only. |
| `curiobase_structured_ratings_min_voters` | `5` | Minimum voters on the primary pairing before stars are emitted. |
| `curiobase_buy_links_enabled` | off | The "Find a copy" line. |
| `curiobase_amazon_tag` | — | Amazon Associates tag. Covers Amazon and AbeBooks. |
| `curiobase_ebay_campaign` | — | eBay Partner Network campaign id. |
| `curiobase_gog_tracking_prefix` | — | GOG affiliate tracking prefix — a full URL, not an id. |

Each shop stays hidden until its id is set. The free half of "Find a copy" needs no configuration.

When structured ratings are on, Google sees **one** `AggregateRating` per Work URL from the pairing
with the most voters (not an average across all Subject tags). Likes/recommends are never exported
as ratings.

### Vote weight

Trust levels 1–4 count 1–4. Staff count 5. Supporters get +1, capped at 5. Trust level 0 can hold a
vote on record but it counts nothing. Weight is read at display time, so it follows a member's
current standing rather than freezing at the moment they voted.

---

## Writing a record

Put a fenced `curiobase` block at the top of the first post. The topic title is the record's title.

**This is the only production authoring format.** Legacy `[wrap=…]` markers remain readable until
converted; do not add new wraps.

A Work:

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

A Subject:

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

Drag an image into the post and it becomes the poster (Works, 2:3) or the plate (Subjects, 3:2).

### Vocabulary

| | |
|---|---|
| `type` | `work` · `subject` |
| `medium` | `film` `series` `book` `game` `video` `document` |
| `mode` | `fiction` · `nonfiction` |
| `kind` | `idea` `incident` `claim` `person` `place` `object` `org` `document` |
| `domain` | `time` `reality` `consciousness` `contact` `phenomena` `hidden-history` `esoterica` `science` `control` `futures` |
| `status` | `open` `contested` `explained` `debunked` `hoax-admitted` `unfalsifiable` |
| `period` | `ancient` `pre-1950` `1950s` … `2020s` |
| `evidence` | `primary-source` `firsthand-account` `secondhand-account` `physical-trace` `documentary-record` `no-evidence` |
| identifiers | `imdb` `tmdb` `isbn` `igdb` `youtube` `archive_org` `wikipedia` `asin` |

Required: a Work needs `slug`, `medium`, `dek`. A Subject needs `slug`, `kind`, `domain`, `dek`.

Per-kind facts: **incident** `began ended where witnesses outcome` · **claim** `asserted claimant` ·
**person** `born died active nationality known_for` · **place** `country active` · **object**
`object_kind provenance whereabouts` · **org** `founded dissolved org_kind jurisdiction` ·
**document** `source_site section transmitted captured operator`

Unknown keys and values outside these lists are rejected in the composer, with the offending value
and the allowed set named in the error. Keep the `dek` under about 155 characters — it becomes the
page's meta description.

### Connecting a Work to a Subject

Tag the Work's topic with the Subject's slug. That tag *is* the pairing, and it is what makes the
Work appear in the Subject's association list and become rateable. Adding or removing a Subject tag
rebakes the card (throttled).

---

## Rake tasks

| | |
|---|---|
| `curiobase:doctor` | Health check — stale claims, slug collisions, records missing a medium or a cached kind. |
| `curiobase:rebake` | Re-render every record. No revisions, no bumps. |
| `curiobase:annotate` | Backfill community wikis for existing records (setting must be on). |
| `curiobase:convert` | Move a legacy `[wrap]` into a fenced block. Refuses rather than dropping a field. |
| `curiobase:repair[write]` | Restore anything an earlier conversion dropped. |
| `curiobase:unclaim` | Release stale slug claims. |
| `curiobase:seed` | Local demo topics (fenced blocks). |

Run `curiobase:doctor` after any bulk change.

---

## Development

Local Discourse docker-dev should track **`tests-passed`** (prod `latest`). From WSL:

```bash
~/sync-discourse-latest   # or: bin/sync-discourse-latest
```

That pulls Discourse, remounts this plugin from
`Documents/GitHub/tti-curiobase`, migrates, and starts `bin/dev`.

```bash
# inside the Discourse container / via d/rspec
LOAD_PLUGINS=1 bin/rspec plugins/tti-curiobase/spec
bin/qunit --standalone --target tti-curiobase   # needs a browser in the container

# Googlebot / crawler smoke (host; Discourse on :3000)
python3 bin/smoke-googlebot.py http://127.0.0.1:3000
```

Records render through `post_process_cooked` into `posts.cooked`, so **a change to the renderer
needs a rebake before it is visible**. Ruby under `lib/` and `config/settings.yml` need a server
restart; `app/` reloads. SCSS changes recompile with the asset pipeline — hard-refresh the browser.

Planning / rollout: [`docs/V1-PRODUCTION-PLAN.md`](docs/V1-PRODUCTION-PLAN.md).

## License

MIT
