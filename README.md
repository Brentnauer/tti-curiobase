# tti-curiobase

A Discourse plugin that turns topics into a catalogue.

Some topics are about a *thing* — a film, a book, a recovered document — and some are about an
*idea* the thing engages with. This plugin lets you say which is which, connect them, and let
members rate how strongly each one pulls on the other.

Records are written in the post itself, rendered into the page, and readable by search engines
without JavaScript. Nothing is moved: a topic keeps its replies, its links and its history.

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

**A community wiki** as post 2 of every record, so corrections live beside the record.

**"Find a copy."** Free sources first — Internet Archive, libraries, Steam, streaming lookups —
then affiliate links, marked as paid. If a work is freely available, the shops are not shown.

**Structured data.** Works are emitted as `Movie`, `Book`, `VideoGame`, `TVSeries`, `VideoObject`
or `CreativeWork`; Subjects as `Person`, `Organization`, `Event`, `Place`, `Claim` and others, with
`sameAs`, `image`, ISBNs, credits, dates and coordinates where the record has them.

---

## Requirements

Discourse 2.7.0 or later. No database migrations — votes live in `PluginStore` and caches in topic
custom fields.

## Install

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

Then enable `curiobase_enabled` in **Admin → Settings → Curiobase**.

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
| `curiobase_annotation_enabled` | off | Adds the community wiki. **Turning this on writes a post to every record topic.** |
| `curiobase_buy_links_enabled` | off | The "Find a copy" line. |
| `curiobase_amazon_tag` | — | Amazon Associates tag. Covers Amazon and AbeBooks. |
| `curiobase_ebay_campaign` | — | eBay Partner Network campaign id. |
| `curiobase_gog_tracking_prefix` | — | GOG affiliate tracking prefix — a full URL, not an id. |

Each shop stays hidden until its id is set. The free half of "Find a copy" needs no configuration.

### Vote weight

Trust levels 1–4 count 1–4. Staff count 5. Supporters get +1, capped at 5. Trust level 0 can hold a
vote on record but it counts nothing. Weight is read at display time, so it follows a member's
current standing rather than freezing at the moment they voted.

---

## Writing a record

Put a fenced `curiobase` block at the top of the first post. The topic title is the record's title.

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
Work appear in the Subject's association list and become rateable.

---

## Rake tasks

| | |
|---|---|
| `curiobase:doctor` | Health check — stale claims, slug collisions, records missing a medium or a cached kind. |
| `curiobase:rebake` | Re-render every record. No revisions, no bumps. |
| `curiobase:convert` | Move a record from a legacy `[wrap]` into a fenced block. Refuses rather than dropping a field it cannot express. |
| `curiobase:repair[write]` | Restore anything an earlier conversion dropped. |
| `curiobase:unclaim` | Release stale slug claims. |

Run `curiobase:doctor` after any bulk change.

---

## Development

```bash
bin/rspec plugins/tti-curiobase/spec
bin/qunit --standalone --target tti-curiobase   # needs a browser in the container
```

Records render through `post_process_cooked` into `posts.cooked`, so **a change to the renderer
needs a rebake before it is visible** — the page serves what is already stored. Ruby under `lib/`
and anything in `config/settings.yml` is loaded at boot and needs a server restart; `app/` reloads.

Design notes, and the reasoning behind most of the decisions in here, live in the companion
[`discourse-curiobase`](https://github.com/Brentnauer/discourse-curiobase) repository.

## License

MIT
