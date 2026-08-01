# frozen_string_literal: true

module Jobs
  # Re-render one record's card after its numbers moved.
  #
  # Deferred and throttled by GravityController — see the comment there for why
  # a rebake per vote is the wrong shape.
  #
  # Runs inside Sidekiq, so plain rebake! would be enough: the ProcessPost job
  # it enqueues would get picked up. rebake_now! is used anyway so there is one
  # rebake path in the plugin and no chance of the two drifting.
  class CuriobaseRebake < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.curiobase_enabled
      post = Post.find_by(id: args[:post_id])
      return unless post

      Curiobase.rebake_now!(post)
    rescue StandardError
      # ⚠ A failed rebake must not leave the 60s throttle locked — otherwise a
      #   broken Subject render (or a Sidekiq blip) freezes a stale card until
      #   something else votes after the key expires.
      if post&.topic_id
        Discourse.redis.del("curiobase:rebake:#{post.topic_id}")
      end
      raise
    end
  end
end
