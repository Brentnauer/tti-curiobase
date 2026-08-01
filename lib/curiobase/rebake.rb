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
end
