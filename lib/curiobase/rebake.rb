# frozen_string_literal: true

module Curiobase
  # ⚠ post.rebake! IS NOT THE WHOLE REBAKE.
  #
  #   rebake! writes cook(raw) — the plain markdown pipeline — and then ENQUEUES
  #   Jobs::ProcessPost. It is that job which runs CookedPostProcessor and fires
  #   :post_process_cooked, the only hook this plugin renders from.
  #
  #   Inside the running dev server that is fine: Sidekiq picks the job up a
  #   moment later. Inside a rake task or `rails runner` the process exits first,
  #   so the card is stripped out of cooked and never put back — the topic ends
  #   up worse than before the rebake, silently.
  #
  #   Anything that rebakes outside a request must use this.
  #
  #   Still no revision and no bump: rebake! hardcodes bypass_bump: true, and
  #   ProcessPost only rewrites cooked.
  def self.rebake_now!(post)
    post.rebake!
    Jobs::ProcessPost.new.execute(
      post_id: post.id,
      cook_method: Post.cook_methods[:regular],
    )
    post
  end

  # Throttled rebake for a record topic. Used after votes and subject-tag edits.
  #
  # ⚠ Do NOT rebake on every vote or every tag click. The numbers/rows are baked
  #   into cooked so crawlers see them, but a full cook + MessageBus push per
  #   event is wasteful. One rebake per topic per minute, deferred a few seconds.
  def self.schedule_record_rebake!(topic)
    return if topic.blank?
    return unless TopicRecord.for(topic)

    key = "curiobase:rebake:#{topic.id}"
    return unless Discourse.redis.set(key, "1", ex: 60, nx: true)

    post_id = topic.first_post&.id
    return if post_id.blank?

    Jobs.enqueue_in(5.seconds, :curiobase_rebake, post_id: post_id)
  end

  # Subject file whose association list includes this pairing. Lookup is the
  # cached RecordTopic path (indexed custom field), not a cooked scan.
  def self.schedule_subject_file_rebake!(slug)
    topic_id = RecordTopic.find(slug, type: :subject)
    return unless topic_id

    schedule_record_rebake!(Topic.find_by(id: topic_id))
  end

  # A gravity vote (or tag change that creates/breaks a pairing) updates two
  # baked surfaces: the Work card's gravity row and the Subject file's
  # association list. Each topic keeps its own 60s throttle — a busy Subject
  # is at most one rebake/minute no matter how many Works are rated against it.
  def self.schedule_pairing_rebake!(work_topic, subject_slug)
    schedule_record_rebake!(work_topic)
    schedule_subject_file_rebake!(subject_slug)
  end

end
