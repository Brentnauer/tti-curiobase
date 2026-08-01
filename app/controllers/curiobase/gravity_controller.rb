# frozen_string_literal: true

module Curiobase
  # The authenticated proxy in front of WordPress.
  #
  #   POST /curiobase/gravity   { topic_id, subject, value }
  #   GET  /curiobase/gravity   ?topic_id=&subject=
  #
  # ⚠ THE CLIENT DOES NOT GET TO SAY WHAT IT IS RATING.
  #
  #   It sends a topic and a subject. The server reads the work id off the
  #   topic's own wrap marker and checks the subject is actually a tag on that
  #   topic and actually in the synced vocabulary. A request naming work 999 and
  #   subject "anything" gets a 422, not a row in WordPress.
  #
  #   Everything a browser sends is a claim. The tags are the fact.
  class GravityController < ::ApplicationController
    requires_plugin Curiobase::PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_enabled
    before_action :ensure_voting_open
    before_action :load_pairing

    def show
      render json: {
        mine: VoteStore.for_user(work_id: @work_id, subject: @subject, user_id: current_user.id),
      }.compact
    end

    def create
      value = params[:value].to_i
      unless VoteStore::RANGE.cover?(value)
        return render_json_error(I18n.t("curiobase.errors.bad_value"), status: 422)
      end

      unless current_user.trust_level >= SiteSetting.curiobase_min_trust_level
        return render_json_error(I18n.t("curiobase.errors.trust_level"), status: 403)
      end

      # A rating is cheap to cast and expensive to un-cast. 30 an hour is far
      # more than honest use and far less than a script.
      RateLimiter.new(current_user, "curiobase-gravity", 30, 1.hour).performed!

      VoteStore.cast(
        work_id: @work_id,
        subject: @subject,
        user_id: current_user.id,
        value: value,
      )

      schedule_rebake
      render json: reading_payload(value)
    rescue RateLimiter::LimitExceeded
      render_json_error(I18n.t("curiobase.errors.rate_limited"), status: 429)
    rescue Excon::Error, JSON::ParserError => e
      # ⚠ Never report success for a write that did not land. Source degrades to
      #   nil because a stale card beats a broken page; silently dropping
      #   somebody's rating and animating a confirmation is a different kind of
      #   wrong.
      Rails.logger.error("[curiobase] gravity write failed: #{e.class}: #{e.message}")
      render_json_error(I18n.t("curiobase.errors.upstream"), status: 502)
    end

    # ⚠ NO TRUST-LEVEL CHECK AND NO RATE LIMIT ON THE WAY OUT.
    #
    #   Taking your own vote back is not a privileged act, and someone who has
    #   hit the hourly cap must still be able to undo the last thing they did.
    #   Locking a member into an opinion they no longer hold is worse than any
    #   abuse this could enable — there is nothing to abuse, since a retraction
    #   can only remove a row the caller already owns.
    def destroy
      VoteStore.retract(work_id: @work_id, subject: @subject, user_id: current_user.id)
      schedule_rebake
      render json: reading_payload(nil)
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.curiobase_enabled
    end

    # ⚠ 404, not 403. With voting off there is no rating control anywhere in the
    #   HTML, so a request reaching here is a stale tab or a script. Neither is
    #   owed an explanation of a feature that is not running.
    def ensure_voting_open
      raise Discourse::NotFound unless SiteSetting.curiobase_member_voting_enabled
    end

    def load_pairing
      topic = Topic.find_by(id: params[:topic_id])
      raise Discourse::NotFound unless topic
      guardian.ensure_can_see!(topic)

      ref = Curiobase::TopicRecord.for(topic)
      raise Discourse::InvalidParameters.new(:topic_id) unless ref && ref[:kind] == "work"

      @subject = params[:subject].to_s
      unless Curiobase::Subjects.for_topic(topic).include?(@subject)
        raise Discourse::InvalidParameters.new(:subject)
      end

      @topic = topic

      # ⚠ VOTES ARE KEYED BY THE WORK'S SLUG, NOT BY WHATEVER THE WRAP SAYS.
      #
      #   A wrap may carry a slug or a legacy numeric id, and Gravity reads the
      #   store by slug. Keying the write off the raw wrap meant a vote was
      #   saved under `votes:123:causal-loop` and read under
      #   `votes:primer-2004:causal-loop` — it saved, returned 200, and vanished.
      #   Resolve once, here, so there is one key for one pairing.
      record = Curiobase::Source.work(ref[:id])
      raise Discourse::InvalidParameters.new(:topic_id) unless record
      @work_id = Gravity.work_id(record) || ref[:id]
    end

    # What the client repaints from.
    #
    # ⚠ It must be the SAME number the server would bake, or the row changes
    #   under the reader when the rebake lands a minute later and they conclude
    #   their vote was thrown away. So this recomputes the blend rather than
    #   returning the raw member aggregate the vote store hands back.
    def reading_payload(mine)
      reading = Gravity.for({ "slug" => @work_id }, @subject)
      {
        mine: mine,
        display: reading&.display,
        voter_count: reading&.voter_count.to_i,
        # nil below two voters, so the client draws no bar — same rule as the
        # baked card. See Gravity::Reading#distributed?.
        distribution: reading&.distributed? ? reading.distribution : nil,
      }
    end

    # ⚠ Do NOT rebake on every vote.
    #
    #   The numbers are baked into cooked so crawlers and no-JS readers see
    #   them, which means every rating technically invalidates the HTML. Acting
    #   on that literally would rebake a popular record once per vote, and a
    #   rebake is a full cook plus a MessageBus push to every open client.
    #
    #   The voter already has the fresh number — it is in this response. The
    #   baked copy may lag a minute, and nobody can perceive that. One rebake
    #   per post per minute, claimed with a Redis key.
    def schedule_rebake
      key = "curiobase:rebake:#{@topic.id}"
      return unless Discourse.redis.set(key, "1", ex: 60, nx: true)
      Jobs.enqueue_in(5.seconds, :curiobase_rebake, post_id: @topic.first_post&.id)
    end
  end
end
