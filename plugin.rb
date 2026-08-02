# frozen_string_literal: true

# name: tti-curiobase
# about: A catalogue of works and the subjects they circle, authored in the posts themselves and baked into the page.
# version: 0.1.0
# authors: Time Travel Institute
# url: https://github.com/Brentnauer/tti-curiobase
# required_version: 3.2.0

enabled_site_setting :curiobase_enabled

register_asset "stylesheets/curiobase.scss"

module ::Curiobase
  PLUGIN_NAME = "tti-curiobase"
end

require_relative "lib/curiobase/engine"
require_relative "lib/curiobase/source"
require_relative "lib/curiobase/rebake"
require_relative "lib/curiobase/standing"
require_relative "lib/curiobase/vote_store"
require_relative "lib/curiobase/topic_kind"
require_relative "lib/curiobase/record_topic"
require_relative "lib/curiobase/recommendations"
require_relative "lib/curiobase/post_kind"
require_relative "lib/curiobase/identifiers"
# ⚠ Must be required, not autoloaded. `app/` is Zeitwerk's; `lib/` is not, and a
#   class in app/services that `include`s a lib module needs it loaded first.
require_relative "lib/curiobase/markup"

# ══════════════════════════════════════════════════════════════════════════
# KEEP THIS FILE THIN.
#
# Anything required here is loaded once at boot and needs a full server
# restart to pick up a change. Anything under app/ or lib/ behind the engine
# is autoloaded by Zeitwerk and reloads on refresh.
#
# That difference is the whole iteration loop. Registration goes here; logic
# goes in app/services and app/controllers.
# ══════════════════════════════════════════════════════════════════════════

after_initialize do
  # ── YouTube players inside Curiobase cards ──────────────────────────────
  #
  # PrettyText only keeps <iframe> srcs whose prefix is on this list (and has
  # ≥3 slashes). Without youtube.com/embed here, our stage players are
  # stripped on any path that re-sanitises cooked HTML, and watch-URL leftovers
  # surface as Discourse oneboxes instead of our card chrome.
  register_modifier(:pretty_text_allowed_iframes) do |list|
    extras = Curiobase::Embeds::ALLOWED_IFRAME_PREFIXES
    extras.reduce(list) { |acc, prefix| acc.include?(prefix) ? acc : acc + [prefix] }
  end

  # ── the render path ─────────────────────────────────────────────────────
  #
  # CookedPostProcessor hands over the Nokogiri document after sanitisation
  # and before posts.cooked is written. Whatever goes in here is in the
  # database, in the crawler view, and visible with JavaScript disabled.
  #
  # ⚠ Never write to post.raw. That writes a revision, bumps the topic, and
  #   races with every human editing the post. post.rebake! hardcodes
  #   bypass_bump: true and writes no revision — that is the reconciliation
  #   path.
  on(:post_process_cooked) do |doc, post|
    next unless SiteSetting.curiobase_enabled
    Curiobase::CardRenderer.new(doc, post).render!
  rescue => e
    # A card that fails to render must never take the post down with it -- but
    # a rescue that hides the reason is worse than the crash. Log the class and
    # the first frames, always.
    Rails.logger.error(
      "[curiobase] render failed on post #{post&.id}: #{e.class}: #{e.message}\n" +
      Array(e.backtrace).first(8).join("\n")
    )
  end

  # ── structured data ─────────────────────────────────────────────────────
  #
  # A reference work wants Movie / Book / Person in the crawler head, not
  # DiscussionForumPosting. The aggregateRating in particular: under any
  # client-side design those numbers are invisible to Google, which would make
  # the one output this system exists to produce the one thing nobody can see.
  register_html_builder("server:before-head-close-crawler") do |controller|
    next "" unless SiteSetting.curiobase_enabled
    Curiobase::JsonLd.for_controller(controller)
  end

  # ── ?curiobase=film on the tag page ─────────────────────────────────────
  #
  # Filters Discourse's OWN topic list, server-side, in SQL. The filter chips
  # on a Subject card are therefore real links: a crawler follows one and gets
  # a complete, different page, and a reader with no scripting gets the same.
  #
  # ⚠ add_custom_filter also adds the key to public_valid_options, which is
  #   what lets the parameter survive TopicQuery's assert_valid_keys. Without
  #   that call the param is not merely ignored — it raises.
  Curiobase::TopicKind.register!
  Curiobase::RecordTopic.register!
  Curiobase::SeriesEpisodes.register!
  Curiobase::GoogleBooks.register!
  # The poster URL, so a Subject's association list can show thumbnails without
  # opening every Work's post. Written by CardRenderer at bake time.
  ::Topic.register_custom_field_type(Curiobase::CardRenderer::POSTER_FIELD, :string)

  TopicQuery.add_custom_filter(:curiobase) do |results, topic_query|
    kind = topic_query.options[:curiobase].to_s
    if kind.blank? || !Curiobase::SubjectCard::FILTERS.include?(kind)
      results
    elsif kind == "discussion"
      # Everything that is NOT a record. A thread is the default state of a
      # topic, so it is defined by absence rather than by a value.
      #
      # ⚠ Through TopicKind, so this and Associations cannot drift. They already
      #   did once: the association list defined a discussion as "not one of the
      #   Works I loaded" and started listing the Subject's own file.
      Curiobase::TopicKind.discussions(results)
    else
      Curiobase::TopicKind.of_kind(results, kind)
    end
  end

  # ── the banner travels WITH the topic list ──────────────────────────────
  #
  # ⚠ This exists to kill a flash, and the flash was not what it looked like.
  #
  #   The banner is server-rendered into Discourse's preload-content block, so
  #   it is on screen before any JavaScript runs. Then Ember boots and replaces
  #   the whole of #main-outlet, throwing it away. An earlier version fetched it
  #   back afterwards, which meant the banner appeared, vanished, and returned.
  #
  #   Shipping the markup on the list payload means the connector has it at
  #   first render: no second request, and nothing to re-insert.
  #
  # HTML, not JSON, on purpose: SubjectCard is the one renderer, and shipping
  # markup means the connector cannot render it differently from the crawler
  # view or the topic card.
  add_to_serializer(:topic_list, :curiobase_banner, respect_plugin_enabled: false) do
    next nil unless SiteSetting.curiobase_enabled

    slug = object.tags&.first&.name
    next nil if slug.blank?
    next nil unless Curiobase::Subjects.vocabulary.include?(slug)

    card = Curiobase::SubjectCard.for_slug(
      slug,
      variant: :banner,
      active_filter: scope&.request&.params&.dig("curiobase"),
    )
    next nil unless card

    { "slug" => slug, "html" => card.to_html }
  end

  # ── the numbers travel with the list too ────────────────────────────────
  #
  # ⚠ ON THE LIST, NOT ON EACH ITEM, because gravity is a property of the
  #   PAIRING and only the list knows which subject is being viewed.
  #   `topic_list_item` has no idea it is being rendered on /tag/excalibur, so
  #   a per-item serializer could serve the medium and the recommendation count
  #   but never the score. One payload, computed once with the tag in hand.
  #
  # ⚠ Only on Subject tag pages — the same guard as the banner. This is not
  #   computed on /latest, on categories, or on ordinary tags.
  add_to_serializer(:topic_list, :curiobase_scores, respect_plugin_enabled: false) do
    next nil unless SiteSetting.curiobase_enabled

    slug = object.tags&.first&.name
    next nil if slug.blank?
    next nil unless Curiobase::Subjects.vocabulary.include?(slug)

    Curiobase::Associations
      .new(slug)
      .rows
      .each_with_object({}) do |row, out|
        next unless row.kind == "work"
        id = row.url[%r{/t/[^/]+/(\d+)}, 1]
        next if id.blank?
        out[id] = {
          "medium" => row.medium,
          "gravity" => row.gravity&.display,
          "recommend" => row.recommendations.to_i,
        }
      end
  end

  # ── a broken record never gets saved ────────────────────────────────────
  #
  # Authoring in a textarea needs composer-time refusal — otherwise a bad
  # facet saves cleanly and renders nothing. Plugin::Instance#validate is the
  # Discourse-native form (reload-safe, gated on plugin.enabled?).
  validate(:post, :curiobase_record_is_well_formed) do
    return unless is_first_post?
    return unless Curiobase::PostKind.present?(raw)

    # ⚠ `post:` lets the validator check the slug is not already another
    #   topic's. Without it a second record can claim the same slug and the
    #   tag page quietly serves the wrong file.
    Curiobase::RecordValidator.errors_for(raw, post: self).each { |e| errors.add(:base, e) }
  end

  # ── a deleted member's votes stop counting ──────────────────────────────
  #
  # ⚠ PluginStore has no foreign key, so nothing cascades. Without this a
  #   deleted account goes on scoring every pairing it ever rated, forever.
  on(:user_destroyed) { |user| Curiobase::VoteStore.forget_user(user.id) }

  # ── keep the vocabulary cache honest ────────────────────────────────────
  on(:tag_created)  { Curiobase::Subjects.reset_cache! }
  on(:tag_updated)  { Curiobase::Subjects.reset_cache! }
  on(:tag_destroyed) { Curiobase::Subjects.reset_cache! }

  # ── rebake when a record's subject tags change ──────────────────────────
  #
  # Adding a subject tag must make the gravity row appear. Tag edits via
  # DiscourseTagging fire `:topic_tags_changed` without `:post_edited`, so
  # both hooks are required. Throttled like vote rebakes — one per topic per
  # minute. Outside a request, use Curiobase.rebake_now! (see rebake.rb).
  on(:post_edited) do |post, topic_changed|
    next unless SiteSetting.curiobase_enabled
    next unless post.is_first_post?
    next unless topic_changed
    Curiobase.schedule_record_rebake!(post.topic)
  end

  on(:topic_tags_changed) do |topic, payload|
    next unless SiteSetting.curiobase_enabled

    old_names = Array(payload&.dig(:old_tag_names) || payload&.dig("old_tag_names"))
    new_names = Array(payload&.dig(:new_tag_names) || payload&.dig("new_tag_names"))
    touched = (old_names + new_names).map(&:to_s).uniq
    next if touched.empty?

    touched_subjects = touched.select { |name| Curiobase::Subjects.vocabulary.include?(name) }
    next if touched_subjects.empty?

    # Work card (gravity rows) and each Subject file whose association list
    # gained or lost this Work — both throttled independently.
    Curiobase.schedule_record_rebake!(topic)
    touched_subjects.each { |slug| Curiobase.schedule_subject_file_rebake!(slug) }
  end

  # ── routes ──────────────────────────────────────────────────────────────
  #
  # Plain routes into Discourse's own route set. NOT a mounted engine: the
  # mount appeared in the route table but the engine's own route set came back
  # empty, so everything under it 404'd. See lib/curiobase/engine.rb.
  # ⚠ The vote endpoint is the only route this plugin owns.
  #
  #   /curiobase/subject/:slug/banner was removed: it rendered a banner to any
  #   anonymous caller and nothing had fetched it since the banner started
  #   travelling on the topic-list payload. A public endpoint with no callers is
  #   surface with no purpose.
  Discourse::Application.routes.append do
    get "/curiobase/gravity" => "curiobase/gravity#show", :defaults => { format: :json }
    post "/curiobase/gravity" => "curiobase/gravity#create", :defaults => { format: :json }
    # Clicking your own mark again takes the vote back.
    delete "/curiobase/gravity" => "curiobase/gravity#destroy", :defaults => { format: :json }
    # Live association scores for a Subject file (batched; complements baked HTML).
    get "/curiobase/readings" => "curiobase/readings#index", :defaults => { format: :json }
  end

  # ⚠ REQUIRED. Routes appended during after_initialize do not take effect
  #   until the route set is reloaded — without this the append silently does
  #   nothing and every path 404s while the plugin looks perfectly healthy.
  Rails.application.reload_routes!

  Rails.logger.warn("[curiobase] loaded — hooks registered")
end
