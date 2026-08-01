# tti-curiobase

A Discourse plugin. A catalogue of **Works** and the **Subjects** they circle, authored in the posts
themselves and baked into the page.

Design docs live in `discourse-curiobase/` — start at `notes/ARCHITECTURE.md` and `notes/DECISIONS.md`.

---

## What it does

A staff member writes a fenced block at the top of a post:

````
```curiobase
type: work
slug: primer-2004
medium: film
year: 2004
creator: Shane Carruth
dek: Two engineers building something in a garage discover their device leaves
  objects with a repeating temporal anomaly.
```
````

The plugin parses that, validates it **in the composer**, and **bakes a card into `posts.cooked`** —
so it is in the database, in the crawler view, and visible with JavaScript off. The topic keeps its
replies, its inbound links and its search position.

Subjects come from Discourse tags. Ratings are cast here and stored in Discourse.

⚠ **A fenced block, not BBCode, and the reason is failure mode** (D-029). A block whose parser never
runs renders as a visible code block. A `[wrap=…]` that fails renders as *nothing* — which is how
every Work card went missing for weeks without anyone noticing.

---

## ⚠ Three rules that shape everything

**1 · No database tables. No migrations.**

Votes live in `PluginStore`, which is core Discourse. Caches live in topic custom fields. If you
find yourself writing a migration, the design has drifted.

**2 · Never write to `post.raw`.**

Generated markdown in `raw` writes a revision on every refresh, bumps the topic to `/latest`, and
races with any human editing the post. Two writers, one field.

Write to **`cooked`** via `post_process_cooked`, and reconcile with `Curiobase.rebake_now!` — which
hardcodes `bypass_bump: true` and writes no revision.

**3 · One door per fact.**

`Source` is the only way to get a record. `TopicRecord` is the only thing that knows both the fenced
block and the legacy wrap. `Gravity.work_id` is the only derivation of a work's id. `Markup` is the
only set of node helpers.

This is not tidiness. **A check that knows only one of the two ways a thing can exist has been this
codebase's single most expensive bug, seven times over** — see `notes/DECISIONS.md`, D-031 through
D-033. Every one of those doors exists because the alternative already failed.

---

## Layout

```
plugin.rb                          registration only — changes need a restart
lib/curiobase/                     boot-time modules; NOT Zeitwerk's, need require_relative
app/services/curiobase/            logic — Zeitwerk reloads this
app/controllers/curiobase/         endpoints — Zeitwerk reloads this
app/views/connectors/              server-rendered outlets; adding one needs a restart
assets/javascripts/discourse/      the rating control and the tag banner
assets/stylesheets/curiobase.scss  the look
config/settings.yml                site settings
fixtures/                          records still on a legacy wrap; also the schema shakedown
```

⚠ **`lib/` is not Zeitwerk's.** A class in `app/services` that `include`s a module from `lib/` needs
an explicit `require_relative` in `plugin.rb` first. Without it every spec errors at the `include`.

---

## The dev loop, and the four ways it lies to you

**⚠ Every Ruby change needs a restart AND a rebake.** Ctrl-C rails, `./start.sh`, then `./rebake.sh`.

The rebake is not optional and it is the single most common way to conclude, wrongly, that a change
did nothing. `posts.cooked` was written by the *old* renderer; restarting loads the new one but does
not re-run it over anything. The page keeps serving the old HTML out of the database, which looks
exactly like "the code isn't working". This has cost two debugging sessions.

**⚠ Front-end changes need terminal 2 restarted too.** Plugin JavaScript does not hot-rebuild:
editing a `.gjs` and reloading serves a byte-identical bundle, same digest, old code compiled in.
`inotify` does not work across `/mnt/c`, so the bundler never sees the file change.

```bash
curl -s http://localhost:3000/ | grep -o '/assets/js/plugins/tti-curiobase_main[^"]*\.js'
```

An unchanged digest means the code you are reading is not the code that ran.

**⚠ Plugin `app/` constants are autoloaded once, on first reference, and never reloaded.** Measured,
not assumed.

**The trap that makes that look untrue.** A constant that has not been referenced yet is read from
disk the first time something uses it. Edit a file the server has not touched since boot, trigger
the first request that needs it, and the change appears — looking exactly like hot reloading. It is
not. It happened once with `json_ld.rb` and briefly convinced me of the opposite of the truth. If a
Ruby change seems to have taken effect without a restart, that file had never been loaded.

### Iterating on the renderer without restarting

There is one real shortcut. The card lives in `posts.cooked`, in the database, and the page serves
whatever is stored there — so a **fresh** process can bake new output that the stale server then
happily serves:

```bash
docker exec -u discourse:discourse -w /src discourse_dev bin/rails runner some_script.rb
```

Every `rails runner` boots its own process, so it has the current code.

⚠ **`post.rebake!` alone is not enough.** It writes `cook(raw)` — the plain markdown pipeline — and
then *enqueues* `Jobs::ProcessPost`, which is what actually runs `CookedPostProcessor` and fires
`:post_process_cooked`. In the dev server Sidekiq picks that up moments later; in a runner the
process exits first, leaving `cooked` stripped of the card. Use `Curiobase.rebake_now!(post)`, which
runs the job inline.

This covers the renderer only. JSON-LD is built per request by the long-running server, so that
still needs a restart.

⚠ **The `d/` scripts use `docker exec -it`** and die with `the input device is not a TTY` when
called from anything that is not an interactive terminal. From a script, call `docker exec` directly
with `-u discourse:discourse -w /src` — that is all `d/exec` meaningfully adds.

---

## Settings

All under **Curiobase** in `/admin/site_settings`.

| | |
|---|---|
| `curiobase_enabled` | master switch, default **off** |
| `curiobase_subject_tag_group` | the tag group holding the Subject vocabulary |
| `curiobase_min_trust_level` | minimum TL to rate, default 1 |
| `curiobase_member_voting_enabled` | default **on**. Gravity *is* the vote — off means no number at all, not a fallback |
| `curiobase_supporter_group` | a group picker; members get **+1** vote weight, capped at 5 |
| `curiobase_annotation_enabled` | default **off**. Turning it on **writes a post** to every record topic |
| `curiobase_buy_links_enabled` | default **off**. The "Find a copy" line |
| `curiobase_amazon_tag` | Associates tag. **Covers Amazon and AbeBooks** |
| `curiobase_ebay_campaign` | eBay Partner Network campaign id |
| `curiobase_gog_tracking_prefix` | a whole tracking **URL prefix**, not an id |

A tag outside the subject group is an ordinary tag and creates no rating row — adding `funny` to a
topic does nothing.

⚠ **The top-level key in `settings.yml` is `curiobase:`, not `plugins:`.** That is what names the
admin page; under `plugins:` the title fell back to the directory name and read *"Tti curiobase"*.
It pairs with `admin_js.admin.site_settings.categories.curiobase` in `client.en.yml` — either alone
leaves a translation-missing string in the heading.

⚠ **A shop with no configured id renders nothing.** The reader never sees a naked affiliate link and
the site never carries a button that earns nothing. The free half of the line — Internet Archive,
libraries, Steam, streaming lookup — needs no configuration at all.

---

## Two surfaces, one renderer

A Subject appears in two places, and `Curiobase::SubjectCard` builds both:

| | Variant | Rendered by |
|---|---|---|
| the record topic `/t/john-titor/9` | `:full` — card, facts, association list | `CardRenderer`, baked into `cooked` |
| the tag page `/tag/john-titor/3` | `:banner` — badges, dek, chips, link | a crawler connector for bots; `curiobase_banner` on the topic-list payload for the app |

**The record topic is canonical.** It holds the JSON-LD, the replies and whatever inbound links the
archive accumulated. The banner is deliberately short so the tag page is a genuinely different page
rather than a near-duplicate splitting its own ranking.

⚠ **The app is given markup, not JSON.** Returning the record and rebuilding the card in JavaScript
is how two renderers drift until the one Google sees is missing a field. `SubjectCard` builds through
Nokogiri, so every value is escaped as a text node or an attribute — which is what makes `htmlSafe`
in the connector safe.

⚠ **A topic is the file for a slug because it says so** (D-033). No setting, no field on the tag.
Reads *verify* the claim against the post rather than trusting the `curiobase_slug` index, and the
lookup is type-scoped so a Work cannot answer for a Subject. `curiobase:doctor` reports collisions
and stale claims; `curiobase:unclaim` releases them.

### Why the banner is on the serializer

It ships on `topic_list.curiobase_banner` so the connector has it at first render. That is not a
performance nicety, it fixes a visible flash — and the flash was not what it looked like:

1. the server renders the banner into Discourse's `preload-content` block, so it is on screen before
   any JavaScript runs
2. Ember boots and **replaces the whole of `#main-outlet`**, discarding it
3. the first version fetched it back in `onPageChange`, so it appeared, vanished, and returned

It was never a slow load. It was a round trip re-fetching something the page had already been given.

⚠ The `before-topic-list` outlet only receives `category` and `tag` — **not** the list. The connector
reads it off the resolved route model instead, which is why it is a `.gjs` component and not an
api-initializer. And `add_to_serializer(:tag, …)` would not work either: `routes/tag/show.js` builds
the tag with `store.createRecord`, so it never sees `TagSerializer` output.

⚠ **Adding a file under `app/views/connectors/` needs a full restart.** Connector templates are
globbed into a frozen constant at class-load (`application_helper.rb`). A new one will not appear on
reload, and its absence looks identical to a broken template.

### Filter chips

`?curiobase=film` narrows **Discourse's own topic list**, in SQL, via `TopicQuery.add_custom_filter`.
The chips are real links: a crawler follows one and gets a complete, different page.

That works because `CardRenderer` caches each record's medium in a topic custom field at bake time.
Without it the filter would mean parsing every topic's first post on a route crawlers hit constantly.
`discussion` is the absence of that field, because a thread is the default state of a topic.

⚠ `add_custom_filter` also adds the key to `public_valid_options`. Without that call the parameter
does not get ignored — `TopicQuery#assert_valid_keys` **raises**.

⚠ **`add_custom_filter` is only half the feature.** It makes the *server* accept the param. The
client half is `api.addDiscoveryQueryParam("curiobase", …)`; without it Ember intercepts the link,
transitions the route to itself, and the list never reloads. No error, no navigation, no change.

⚠ Link `/tag/<slug>/<id>`, not `/tag/<slug>`. The short form 301s, and a baked link that always
redirects is a wasted hop on every crawl forever.

---

## Rating: what is baked and what is not

`posts.cooked` is **one blob served to everybody** — a crawler, an admin, and the person who rated
this yesterday all get identical bytes, cached for months. So the split is forced, not chosen:

| | where | why |
|---|---|---|
| mean, voter count, distribution | **baked into cooked** | public, and the only version Google will ever see |
| your own rating, the control | **fetched after load** | user-specific; baking it makes it wrong for every reader but one |

No JavaScript therefore means every number and no control. That is the right way round.

```
POST /curiobase/gravity   { topic_id, subject, value }
```

The endpoint re-derives what is being rated from the topic itself: the work id comes off the topic's
own record, and the subject must be a tag on that topic **and** in the vocabulary. A browser naming
work 999 and subject "anything" gets a 422. **Everything a client sends is a claim; the tags are the
fact.**

⚠ **Voting does not rebake immediately.** Every rating technically invalidates the baked HTML, but
acting on that literally would rebake a popular record once per vote — a full cook plus a MessageBus
push to every open client. The voter already has the fresh number in their response, so the baked
copy is allowed to lag: one rebake per post per minute, claimed with a Redis key.

---

## Rake tasks

| | |
|---|---|
| `curiobase:doctor` | the health check. Stale claims, slug collisions, Works with no medium |
| `curiobase:rebake` | re-render every record — no revisions, no bumps |
| `curiobase:convert` | move a record from a legacy wrap into a fenced block. **Refuses on any field it cannot express** |
| `curiobase:repair[write]` | put back what an earlier convert dropped silently |
| `curiobase:unclaim` | release stale slug claims |

⚠ **`convert` refusing is the feature** (D-031). An earlier version discarded a field on six of 34
records and reported success on every one, because validating the *output* cannot see a field the
writer could not express. `RecordWriter.losses` compares against the **input**.

---

## Tests

```bash
docker exec -u discourse:discourse -w /src -e LOAD_PLUGINS=1 -e RAILS_ENV=test \
  discourse_dev bin/rspec plugins/tti-curiobase/spec
```

JavaScript, which needs a browser in the container:

```bash
apt-get install chromium          # will not survive a container rebuild
DISCOURSE_DISABLE_BROWSER_SANDBOX=1 bin/qunit --standalone --target tti-curiobase
```

⚠ The correct invocation is `--target`, not `--filter`. `--filter` alone reports *"No tests
matched"*, because plugin tests are not in the bundle unless targeted.

Or `../discourse-local/verify.sh`, which runs both plus the rebake, the crawler view of every kind,
and a usability gate.

**Most specs are regression tests for bugs that actually shipped, and each says so in a comment.**
The gate worth knowing about is in `verify.sh`: it asserts a rendered card is **usable**, not merely
present. Three defects shipped in one day — blank titles on all 34 records, silently dropped facts,
and a rating control that never mounted — and all three passed `doctor`, `verify.sh` and a full QA
sweep, because every check asked *"did a card render?"* and the answer was honestly yes.

⚠ In a request spec, do not name a fabricator `post` — `fab!(:post)` shadows the `post` request
helper and every request in the file dies with *"wrong number of arguments (given 2, expected 0)"*.

---

## The crawler exit test

The thing everything else assumes:

```bash
curl -s -H 'User-Agent: Googlebot' http://localhost:3000/t/SLUG/ID \
  | sed 's/<script[^>]*>.*<\/script>//g' | sed 's/<[^>]*>/ /g' | tr -s ' '
```

The dek, the facts and the subject names must all be in that output. **If they are not, stop** —
everything downstream assumes it.
