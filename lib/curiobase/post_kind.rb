# frozen_string_literal: true

module Curiobase
  # Does this post carry a record, and which one?
  #
  # ⚠ The same job TopicRecord does for wraps, for post-authored records. It
  #   lives in lib/ rather than app/services/ because the Post validator in
  #   plugin.rb needs it at boot, before app/ autoloading is available.
  module PostKind
    FENCE = /^```curiobase\s*\n(.*?)\n```/m

    def self.present?(raw) = raw.to_s.match?(FENCE)

    # ⚠ EVERY SWEEP OVER THE CATALOGUE MUST USE THIS.
    #
    #   There are two ways to author a record and four things that walk them
    #   all: rebake, doctor, annotate, and verify.sh. Each one was written when
    #   there was only one way, and each one silently skipped the converted
    #   record — `curiobase:rebake` reported 33 posts when there were 34, and
    #   nothing about a smaller number looks like a bug.
    #
    #   One scope, so a third authoring format could only ever be missed once.
    def self.first_posts
      ::Post
        .where(post_number: 1)
        .where(
          "raw ILIKE '%[wrap=work%' OR raw ILIKE '%[wrap=subject%' OR raw LIKE '%```curiobase%'",
        )
    end
  end
end
