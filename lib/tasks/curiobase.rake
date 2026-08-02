# frozen_string_literal: true

# Seeds the full fixture catalogue for local UI testing.
#
#   cd ~/discourse && LOAD_PLUGINS=1 bundle exec rake curiobase:seed
#
# Creates the subject tag group, every fixture subject/work as a fenced
# `curiobase` topic, and tags works from their gravity rows. Idempotent.
#
# ⚠ Fenced blocks are the only production authoring format. Wraps remain
#   readable for legacy topics but new content must not introduce them.
desc "Seed local Curiobase demo content"
task "curiobase:seed" => :environment do
  fixture_root = File.expand_path("../../fixtures", __dir__)

  load_json = lambda do |path|
    JSON.parse(File.read(path))
  rescue StandardError => e
    abort "Cannot read #{path}: #{e.message}"
  end

  subjects =
    Dir[File.join(fixture_root, "subjects", "*.json")].map { |f| load_json.call(f) }
  works =
    Dir[File.join(fixture_root, "works", "*.json")]
      .sort_by { |f| File.basename(f, ".json").to_i }
      .map { |f| load_json.call(f) }

  abort "No subject fixtures in #{fixture_root}/subjects" if subjects.empty?

  admin = User.where(admin: true).order(:id).first
  abort "No admin user. Create one first." unless admin

  # ── vocabulary ──────────────────────────────────────────────────────────
  # A tag outside this group is an ordinary tag and produces no rating row.
  group_name = SiteSetting.curiobase_subject_tag_group
  group = TagGroup.find_or_create_by!(name: group_name)
  tags = subjects.map { |s| Tag.find_or_create_by!(name: s["slug"]) }
  group.tags = (group.tags.to_a + tags).uniq
  group.save!
  puts "  tag group '#{group_name}': #{group.tags.map(&:name).sort.join(', ')}"

  category = Category.find_by(slug: "uncategorized") || Category.first

  # Prefer the topic that already owns this record slug, then title match.
  # Title-only lookup misses when an earlier draft used a different title.
  find_existing = lambda do |slug, type, title|
    topic_id =
      Curiobase::RecordTopic.find(slug, type: type) ||
      Curiobase::RecordTopic.claimants(slug).first
    topic = topic_id && Topic.find_by(id: topic_id)
    topic ||= Topic.find_by(title: title)
    return topic if topic

    # Last resort: a live first-post already claims the slug in its fence/wrap
    # but the custom-field cache was never written (common after partial seeds).
    Post
      .where(post_number: 1)
      .where("raw ILIKE ?", "%slug: #{slug}%")
      .includes(:topic)
      .find_each do |post|
        next if post.topic&.deleted_at
        ref = Curiobase::TopicRecord.for(post.topic)
        next unless ref && ref[:id].to_s == slug
        return post.topic
      end
    nil
  end

  upsert_topic = lambda do |slug, type, title, raw, tag_names|
    existing = find_existing.call(slug, type, title)
    if existing
      # Keep the catalogue title in sync with the fixture.
      if existing.title != title
        existing.title = title
        existing.save!(validate: false)
      end
      post = existing.first_post
      revisor = PostRevisor.new(post, existing)
      revisor.revise!(admin, { raw: raw, tags: tag_names }, skip_validations: true)
      Curiobase.rebake_now!(post)
      puts "  updated  /t/#{existing.slug}/#{existing.id}  (#{slug})"
      existing
    else
      result = PostCreator.create!(
        admin,
        title: title,
        raw: raw,
        category: category.id,
        tags: tag_names,
        skip_validations: true,
      )
      puts "  created  /t/#{result.topic.slug}/#{result.topic.id}  (#{slug})"
      result.topic
    end
  end

  raw_for = lambda do |record|
    fence = Curiobase::RecordWriter.fence(record)
    body = Curiobase::RecordWriter.body_additions(record, "").join("\n\n")
    [fence, body.presence].compact.join("\n\n").strip
  end

  puts "  subjects (#{subjects.size})"
  subjects.each do |record|
    slug = record["slug"].to_s
    title = record["title"].presence || slug.tr("-", " ").split.map(&:capitalize).join(" ")
    raw = raw_for.call(record)
    errors = Curiobase::RecordValidator.errors_for(raw)
    if errors.any?
      puts "  ✗ skip subject #{slug}: #{errors.first}"
      next
    end
    upsert_topic.call(slug, :subject, title, raw, [slug])
  end

  puts "  works (#{works.size})"
  works.each do |record|
    slug = record["slug"].to_s
    title = record["title"].presence || slug
    raw = raw_for.call(record)
    errors = Curiobase::RecordValidator.errors_for(raw)
    if errors.any?
      puts "  ✗ skip work #{slug}: #{errors.first}"
      next
    end
    tag_names = Array(record["gravity"]).map { |r| r["subject"] }.compact.uniq
    # Untagged works still need a topic so the empty-assessment card is visible.
    upsert_topic.call(slug, :work, title, raw, tag_names)
  end

  puts <<~NEXT

    Enable the plugin if you have not:
      /admin/site_settings — curiobase_enabled

    Then open a subject with typed edges (e.g. Rendlesham Forest) and a multi-
    gravity work (e.g. Primer, Left at East Gate). Subject cards should show
    grouped edge lists; work cards should show association rows for each tag.
  NEXT
end

# ⚠ THE TASK THAT EXISTS BECAUSE NOBODY NOTICED FOR WEEKS.
#
#   Wraps used to name a WordPress post ID. A post ID is environment-specific —
#   Primer is 7223 on the live CMS and 123 in the fixtures — so the moment
#   Discourse was pointed at real WordPress, every Work wrap named a post that
#   did not exist. Source returns nil on a miss and CardRenderer leaves the post
#   alone rather than defacing it, so there was no error anywhere: seven records
#   simply stopped having cards, and the crawler check printed card=0 in a
#   column nobody was reading.
#
#   Slugs are the same string in every environment. This rewrites the old form.
desc "Rewrite numeric work wraps to slugs"
task "curiobase:repoint" => :environment do
  scope = Post.where(post_number: 1).where("raw ~ ?", '\[wrap=work +id=[0-9]+\]')
  puts "Checking #{scope.count} posts"

  changed = 0
  scope.find_each do |post|
    id = post.raw[/\[wrap=work\s+id=(\d+)\]/i, 1]

    # ⚠ THE FIXTURES, NOT THE SOURCE. The numeric id is a FIXTURE id, and the
    #   whole reason these posts are broken is that it means nothing to
    #   WordPress. Asking the live source what work 123 is returns nil forever.
    #   The fixtures are the only place that knows 123 was ever Primer.
    slug = Curiobase::Source::Fixture.new.work(id)&.dig("slug")
    if slug.blank?
      puts "  UNRESOLVED  #{post.topic.slug} — no fixture for work #{id}, cannot name it"
      next
    end

    # And then confirm the slug means something where the site will actually
    # read it, so this never trades one dead reference for another.
    unless Curiobase::Source.work(slug)
      puts "  UNRESOLVED  #{post.topic.slug} — #{id} is #{slug}, but the source has no such work"
      next
    end

    raw = post.raw.sub(/\[wrap=work\s+id=#{Regexp.escape(id)}\]/i, "[wrap=work id=#{slug}]")
    PostRevisor.new(post, post.topic).revise!(
      Discourse.system_user,
      { raw: raw },
      skip_validations: true,
      bypass_bump: true,
      skip_revision: true,
    )
    Curiobase.rebake_now!(post.reload)
    puts "  #{post.topic.slug}: #{id} → #{slug}"
    changed += 1
  end

  puts "Repointed #{changed}."
end

# ⚠ EVERY FAILURE MODE IN THIS SYSTEM IS SILENT, and that is not an accident —
#   it is the correct behaviour repeated. Source returns nil rather than
#   defacing a post. CardRenderer leaves a post alone rather than showing an
#   error. ACF accepts a write to a field that does not exist. None of them can
#   shout, so something has to go looking.
#
#   Run it after any WordPress change.
desc "Find Curiobase records that are quietly broken"
task "curiobase:doctor" => :environment do
  problems = 0
  say = ->(msg) { problems += 1; puts "  ✗ #{msg}" }

  vocabulary = Curiobase::Subjects.vocabulary

  Curiobase::PostKind.first_posts.find_each do |post|
      topic = post.topic
      next if topic.deleted_at
      label = "#{topic.slug}/#{topic.id}"

      # A post-authored record answers for itself; a wrap has to be resolved.
      if Curiobase::PostKind.present?(post.raw)
        errors = Curiobase::RecordValidator.errors_for(post.raw, post: post)
        errors.each { |e| say.call("#{label}: #{e}") }
        next if errors.any?

        record = Curiobase::PostRecord.to_record(Curiobase::PostRecord.parse(post.raw))
        ref = { kind: record["type"], id: record["slug"] }
      else
        ref = Curiobase::TopicRecord.for(topic)
        next say.call("#{label}: wrap present but unparseable") unless ref

        record = ref[:kind] == "work" ? Curiobase::Source.work(ref[:id]) : Curiobase::Source.subject(ref[:id])
        next say.call("#{label}: no #{ref[:kind]} '#{ref[:id]}' in the source — card renders nothing") unless record
      end

      # The caches CardRenderer writes at bake time. Empty means never baked
      # since they shipped, which makes the file unlinkable and miscounted.
      # ⚠ `curiobase_kind` IS NOW LOAD-BEARING, NOT A CACHE.
      #
      #   `Associations#record_topics` selects Works by joining on this field, so
      #   a record without it is not merely slower to find — it is **absent from
      #   the association list and from every filter chip**, while its own card
      #   still renders perfectly. That is this codebase's signature failure
      #   shape, so it is worth saying loudly rather than as a tidiness note.
      if topic.custom_fields[Curiobase::TopicKind::FIELD].blank?
        say.call("#{label}: no cached kind — INVISIBLE to association lists. Run curiobase:rebake")
      end
      if topic.custom_fields[Curiobase::RecordTopic::FIELD].blank?
        say.call("#{label}: no cached slug — run curiobase:rebake")
      end

      # Staff status vs membership split — editorial signal, not a broken record.
      if ref[:kind] == "subject" &&
           Curiobase::SubjectCard::SETTLED_STATUSES.include?(record["status"].to_s)
        split =
          Curiobase::Associations
            .new(ref[:id])
            .rows
            .select { |r| r.kind == "work" && r.gravity&.disagree? }
        if split.any?
          ids = split.map(&:work_id).compact.first(5).join(", ")
          say.call(
            "#{label}: status is '#{record["status"]}' but members disagree on " \
              "#{split.size} pairing(s) (e.g. #{ids}) — check or leave the tension visible",
          )
        end
      end

      if ref[:kind] == "subject"
        Array(record["refs"]).each do |edge|
          next unless edge.is_a?(Hash)
          target = edge["slug"].to_s
          verb = edge["verb"].presence || Curiobase::PostRecord::RELATED
          if verb == "same_as"
            say.call(
              "#{label}: `same_as` → '#{target}' — merge the topics or use also_known_as; " \
              "same_as is not an edge",
            )
          end
          next if target.blank?
          # Vocabulary membership is the composer gate; a missing *file* is the
          # silent failure — both sides of the edge render as nothing useful.
          unless Curiobase::RecordTopic.find(target, type: :subject)
            say.call(
              "#{label}: #{verb} → '#{target}' has no Subject file — " \
              "inbound and the link both go nowhere until one exists",
            )
          end
        end
      end

      next unless ref[:kind] == "work"

      # ⚠ ORPHANED VOTES. Tagging creates the pairing; votes only score it. Untag
      #   a subject and every vote cast on that pairing stops rendering — but the
      #   rows stay in the store, so re-tagging silently resurrects opinions
      #   people formed about a connection that was withdrawn in between.
      tags = topic.tags.map(&:name)
      slug = record["slug"].to_s
      next if slug.blank?

      # ⚠ TAGS THAT CREATE PAIRINGS MUST BE IN THE SUBJECT VOCABULARY.
      #
      #   Gravity rows bake from whatever was in the group at cook time. If a
      #   Subject tag later sits outside `curiobase_subject_tag_group`, the card
      #   can still show a vote control from stale cooked while the endpoint
      #   rejects every cast with InvalidParameters :subject.
      tags.each do |name|
        next if vocabulary.include?(name)
        next unless Curiobase::RecordTopic.find(name, type: :subject)
        say.call(
          "#{label}: tagged '#{name}' which has a Subject file but is not in " \
          "the '#{SiteSetting.curiobase_subject_tag_group}' tag group — votes will 400",
        )
      end

      PluginStoreRow
        .where(plugin_name: Curiobase::VoteStore::PLUGIN)
        .where("key LIKE ?", "votes:#{slug}:%")
        .pluck(:key)
        .each do |key|
          subject = key.split(":", 3).last
          next if tags.include?(subject)
          n = Curiobase::VoteStore.raw(work_id: slug, subject: subject).size
          say.call("#{label}: #{n} vote(s) on '#{subject}' but the topic is not tagged with it — they render nowhere")
        end
    end

  # ── who claims which slug ─────────────────────────────────────────────────
  #
  # ⚠ THE FILE DESIGNATES ITSELF, SO THE CLAIM HAS TO BE EXCLUSIVE.
  #
  #   `curiobase_slug` is a cache pointing at the topic that carries a record.
  #   Nothing released it when a topic stopped being one, so eight claims
  #   survived a rebuild — including one on `majestic-12` from a deleted draft
  #   with a LOWER id than the real file. Reads verify against the post now, so
  #   a stale claim cannot win, but it should still not be sitting there:
  #   archaeology in this table is what makes a real collision hard to see.
  stale = 0
  TopicCustomField.where(name: Curiobase::RecordTopic::FIELD).find_each do |cf|
    next if cf.value.blank?
    topic = Topic.find_by(id: cf.topic_id)
    if topic.nil?
      stale += 1
      puts "  · topic #{cf.topic_id} is gone but still claims '#{cf.value}'"
      next
    end
    # ⚠ TopicRecord, not PostRecord — it is the reader that knows both the
    #   fenced block and the legacy wrap. Parsing directly here would report
    #   every wrap-authored record as stale and invite someone to clear it.
    ref = Curiobase::TopicRecord.for(topic)
    next if ref && ref[:id].to_s == cf.value

    stale += 1
    puts "  · #{topic.slug}/#{topic.id} claims '#{cf.value}' but no longer carries that record"
  end
  puts "  #{stale} stale claim(s) — run bin/rake curiobase:unclaim to clear them" if stale.positive?

  # ⚠ Two LIVE topics genuinely claiming one slug is the ambiguity there is no
  #   right tiebreak for. RecordValidator refuses it at save; this catches any
  #   that predate the check.
  Curiobase::RecordTopic
    .claimants_by_slug
    .each do |slug, ids|
      next if ids.size < 2
      titles = Topic.where(id: ids).pluck(:id, :title).map { |i, t| "#{t} (#{i})" }
      say.call("'#{slug}' is claimed by #{ids.size} live topics: #{titles.join(' · ')} — rename one or merge them")
    end

  # ⚠ `medium` BECAME LOAD-BEARING when the Find-a-copy line started scoping
  #   vendors by it. A Work with no medium gets no vendors at all — deliberate,
  #   over guessing — but that means a missing medium is now a silently emptier
  #   card rather than a cosmetic gap. This codebase's whole history is checks
  #   that never asked whether the rendered thing was usable.
  Curiobase::PostKind.first_posts.find_each do |post|
    next unless Curiobase::PostKind.present?(post.raw)
    record = Curiobase::PostRecord.to_record(Curiobase::PostRecord.parse(post.raw), topic: post.topic)
    next unless record && record["type"] == "work"
    next if record["medium"].present?
    say.call("#{post.topic.slug}/#{post.topic_id} is a Work with no `medium` — it gets no Find-a-copy line")
  end

  puts problems.zero? ? "Nothing broken." : "#{problems} problem(s)."
end

# Clears `curiobase_slug` from topics that no longer carry the record they claim.
# Safe: reads verify against the post, so this only tidies the index.
desc "Release stale record-slug claims"
task "curiobase:unclaim" => :environment do
  cleared = 0
  TopicCustomField.where(name: Curiobase::RecordTopic::FIELD).find_each do |cf|
    next if cf.value.blank?
    topic = Topic.find_by(id: cf.topic_id)

    if topic.nil?
      Curiobase::RecordTopic.forget_cache(cf.value)
      cf.destroy
      cleared += 1
      next
    end

    ref = Curiobase::TopicRecord.for(topic)
    next if ref && ref[:id].to_s == cf.value

    puts "  #{topic.slug}/#{topic.id}: releasing '#{cf.value}'"
    Curiobase::RecordTopic.release(topic)
    cleared += 1
  end
  puts "Released #{cleared}."
end

# ⚠ ONE RECORD AT A TIME, AND REVERSIBLE. Every conversion is a post revision,
#   so Discourse's own history is the undo — there is no separate rollback to
#   write and no state to reconcile if this is abandoned halfway.
#
#   Source prefers a post-authored record over WordPress, so a converted topic
#   moves every surface with it at once: card, tag banner, association list,
#   JSON-LD, doctor. The WordPress record is left exactly where it is.
#
#     bin/rake curiobase:convert            # everything still on a wrap
#     bin/rake curiobase:convert[primer-2004]
desc "Rewrite wrap-authored records as records in their own post"
task "curiobase:convert", [:only] => :environment do |_t, args|
  scope = Post.where(post_number: 1).where("raw ILIKE '%[wrap=work%' OR raw ILIKE '%[wrap=subject%'")
  converted = 0
  refused = 0

  scope.find_each do |post|
    topic = post.topic
    next if topic.deleted_at

    ref = Curiobase::TopicRecord.for(topic)
    next unless ref
    next if args[:only].present? && args[:only] != ref[:id]

    record = ref[:kind] == "work" ? Curiobase::Source.work(ref[:id]) : Curiobase::Source.subject(ref[:id])
    unless record
      puts "  ✗ #{topic.slug}: #{ref[:kind]} '#{ref[:id]}' not in the source — nothing to convert from"
      refused += 1
      next
    end

    # ══════════════════════════════════════════════════════════════════════
    # WOULD THIS CONVERSION LOSE ANYTHING? Ask before writing, not after.
    # ══════════════════════════════════════════════════════════════════════
    #
    # ⚠ VALIDATING THE OUTPUT CANNOT CATCH THIS, and that is why it went
    #   unnoticed. `RecordValidator` inspects the block that was written — but
    #   a field the writer could not express is simply not in that block, so
    #   the validator sees a clean record and says so. The check has to compare
    #   against the INPUT.
    #
    #   Six records were converted with fields silently discarded: John Titor's
    #   nationality and known_for, Skinwalker's country, Excalibur's provenance
    #   and whereabouts, Majestic 12's jurisdiction, Philadelphia's prose,
    #   Voynich's full_text. Every one reported success.
    losses = Curiobase::RecordWriter.losses(record)
    if losses.any?
      puts "  ✗ #{topic.slug}: would drop #{losses.join(', ')} — not converting"
      refused += 1
      next
    end

    fence = Curiobase::RecordWriter.fence(record)

    # ⚠ Keep whatever the author wrote under the wrap. The wrap line goes; the
    #   prose beneath it is theirs and predates all of this.
    body = post.raw.sub(/\[wrap=(?:work|subject)[^\]]*\]\s*(?:\[\/wrap\])?/i, "").strip

    # ⚠ SAME CALL THE REPAIR TASK MAKES. `prose` and `full_text` are too long
    #   for a key-value line and belong in the body — but they only get there if
    #   somebody puts them there, and the first version of this task did not.
    raw = ([fence, body.presence] + Curiobase::RecordWriter.body_additions(record, body))
      .compact.join("\n\n").strip

    errors = Curiobase::RecordValidator.errors_for(raw)
    if errors.any?
      # The WordPress record holds something the flat block cannot express, or
      # something that was never valid. Say which, and leave the topic alone.
      puts "  ✗ #{topic.slug}: #{errors.first}"
      refused += 1
      next
    end

    PostRevisor.new(post, topic).revise!(
      Discourse.system_user,
      { raw: raw },
      skip_validations: false,
      bypass_bump: true,
      skip_revision: false,
    )
    Curiobase.rebake_now!(post.reload)
    puts "  #{topic.slug}: #{ref[:kind]} #{ref[:id]}"
    converted += 1
  end

  puts "Converted #{converted}, refused #{refused}."
  puts "Run bin/rake curiobase:doctor next." if converted.positive?
end

# ⚠ REPAIRS RECORDS CONVERTED BEFORE THE CONVERTER COULD SAY WHAT IT WAS
#   DROPPING. Idempotent, and a no-op once a record is whole.
#
#   `curiobase:convert` ran against a parser whose fact vocabulary was a partial
#   union of the eight kinds, and against a writer that had no way to report a
#   field it could not express. Six records lost data and all six reported
#   success. This puts it back from the fixtures, which are the WordPress shape.
#
#   Three different repairs, because the three losses are not the same shape:
#
#     facts      → back into the fence. The parser understands them now.
#     prose      → into the post body as headed markdown. This is where it was
#                  always meant to live; a flat block cannot hold a repeater and
#                  the body renders it better than a definition list ever did.
#     full_text  → into the post body, last, inside a collapsed [details]. A
#                  recovered document is potentially enormous and must not push
#                  the dek out of the search snippet.
#
#     bin/rake curiobase:repair          # report only
#     bin/rake curiobase:repair[write]
desc "Restore fields dropped by an earlier conversion"
task "curiobase:repair", [:mode] => :environment do |_t, args|
  write = args[:mode].to_s == "write"
  root = File.expand_path("../../fixtures", __dir__)
  repaired = 0
  clean = 0

  fixture_for = lambda do |kind, slug|
    dir = kind == "work" ? "works" : "subjects"
    path = Dir[File.join(root, dir, "*.json")].find do |f|
      (JSON.parse(File.read(f))["slug"].to_s == slug rescue false)
    end
    path && JSON.parse(File.read(path))
  end

  Curiobase::PostKind.first_posts.find_each do |post|
    topic = post.topic
    next if topic.deleted_at

    ref = Curiobase::TopicRecord.for(topic)
    next unless ref
    parsed = Curiobase::PostRecord.parse(post.raw)
    next unless parsed&.valid?

    wp = fixture_for.call(ref[:kind], ref[:id])
    next unless wp

    body = post.raw.sub(/^```curiobase\s*\n.*?\n```/m, "").strip
    restored = []

    # ── facts ──────────────────────────────────────────────────────────────
    missing_facts = (wp["facts"] || {}).reject { |k, v| v.blank? || parsed.fields[k].present? }
    restored << "facts: #{missing_facts.keys.join(', ')}" if missing_facts.any?

    # ── prose and full_text ────────────────────────────────────────────────
    additions = Curiobase::RecordWriter.body_additions(wp, body)
    additions.each { |a| restored << "body: #{a.lines.first.to_s.strip.delete_prefix('### ')[0, 40]}" }

    if restored.empty?
      clean += 1
      next
    end

    puts "  #{topic.slug}"
    restored.each { |r| puts "      + #{r}" }
    repaired += 1
    next unless write

    # Rebuild the fence from the fixture merged over what the post already says,
    # so an edit made since conversion is not reverted by the repair.
    merged = wp.merge(parsed.fields.slice(*Curiobase::PostRecord::SCALARS).compact_blank)
    merged["facts"] = (wp["facts"] || {}).merge(
      Curiobase::PostRecord::FACTS.index_with { |k| parsed.fields[k] }.compact_blank,
    )

    raw = ([Curiobase::RecordWriter.fence(merged), body.presence] + additions)
      .compact.join("\n\n").strip

    errors = Curiobase::RecordValidator.errors_for(raw)
    if errors.any?
      puts "      ✗ refused: #{errors.first}"
      next
    end

    PostRevisor.new(post, topic).revise!(
      Discourse.system_user,
      { raw: raw },
      skip_validations: false,
      bypass_bump: true,
      skip_revision: false,
    )
    Curiobase.rebake_now!(post.reload)
    puts "      ✓ written"
  end

  puts
  puts "#{clean} already whole, #{repaired} #{write ? 'repaired' : 'need repair'}."
  puts "Re-run with [write] to apply." if repaired.positive? && !write
end

desc "Rebake every topic carrying a Curiobase wrap"
task "curiobase:rebake" => :environment do
  ids = Curiobase::PostKind.first_posts.pluck(:id)
  puts "Rebaking #{ids.size} posts"
  Post.where(id: ids).find_each { |post| Curiobase.rebake_now!(post) }
  puts "Done. No revisions written, no topics bumped."
end
