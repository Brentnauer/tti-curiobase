# frozen_string_literal: true

module Curiobase
  # Authenticated gravity votes for a (work, subject) pairing.
  #
  #   POST   /curiobase/gravity   { topic_id, subject, value }
  #   GET    /curiobase/gravity   ?topic_id=&subject=
  #   DELETE /curiobase/gravity   { topic_id, subject }
  #
  # ⚠ THE CLIENT DOES NOT GET TO SAY WHAT IT IS RATING.
  #
  #   It sends a topic and a subject. The server reads the work id off the
  #   topic's own record and checks the subject is actually a tag on that
  #   topic and actually in the vocabulary. A request naming work 999 and
  #   subject "anything" gets a 422, not a row in PluginStore.
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

      Curiobase.schedule_record_rebake!(@topic)
      render json: reading_payload(value)
    rescue RateLimiter::LimitExceeded
      render_json_error(I18n.t("curiobase.errors.rate_limited"), status: 429)
    rescue StandardError => e
      # Never report success for a write that did not land.
      Rails.logger.error("[curiobase] gravity write failed: #{e.class}: #{e.message}")
      render_json_error(I18n.t("curiobase.errors.upstream"), status: 502)
    end

    # ⚠ NO TRUST-LEVEL CHECK AND NO RATE LIMIT ON THE WAY OUT.
    #
    #   Taking your own vote back is not a privileged act, and someone who has
    #   hit the hourly cap must still be able to undo the last thing they did.
    def destroy
      VoteStore.retract(work_id: @work_id, subject: @subject, user_id: current_user.id)
      Curiobase.schedule_record_rebake!(@topic)
      render json: reading_payload(nil)
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.curiobase_enabled
    end

    # ⚠ 404, not 403. With voting off there is no rating control in the HTML,
    #   so a request reaching here is a stale tab or a script.
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

      # ⚠ VOTES ARE KEYED BY THE WORK'S SLUG.
      #
      #   A legacy wrap may still carry a numeric id; Gravity reads the store by
      #   slug. Resolve once here so write and read share one key.
      record = Curiobase::Source.work(ref[:id])
      raise Discourse::InvalidParameters.new(:topic_id) unless record
      @work_id = Gravity.work_id(record) || ref[:id]
    end

    # What the client repaints from — same number the card will bake.
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
  end
end
