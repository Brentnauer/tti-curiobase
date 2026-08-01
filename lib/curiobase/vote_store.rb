# frozen_string_literal: true

module Curiobase
  # Where gravity votes live.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # PluginStore. NO MIGRATION, AND NO WORDPRESS EITHER.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # ⚠ THIS REPLACED TWO WRONG ANSWERS, and it is worth knowing why both were
  #   wrong because the reasoning keeps coming back.
  #
  #   WordPress was the original plan: a table there, reached over
  #   /wp-json/tti/v1/gravity. The goal was right — avoid Discourse-side schema
  #   — but the cost was hidden. A vote is (user, work, subject, value) and
  #   three of those four are Discourse's: the voter, the subject (a tag), and
  #   the weight (trust level and groups). The tag page banner recomputes
  #   association lists PER REQUEST, so remote votes meant an HTTP call per work
  #   on a page crawlers hammer, to fetch rows that then had to be joined
  #   against Discourse users anyway. And deleting a member would leave their
  #   votes scoring records forever, because UserDestroyer cannot reach across
  #   HTTP.
  #
  #   A plugin migration was the second answer, and it solved the performance
  #   while breaking the actual constraint: no new schema in Discourse. A
  #   plugin that adds tables is a plugin that can block ./launcher rebuild.
  #
  #   PluginStore is what Discourse ships for exactly this. `plugin_store_rows`
  #   is a core table with a unique index on (plugin_name, key), and
  #   discourse-calendar, discourse-patreon, discourse-user-notes and
  #   discourse-narrative-bot all keep their data there rather than migrating.
  #
  # ⚠ ONE VOTE PER MEMBER PER PAIRING, and a second cast REPLACES the first.
  #   Changing your mind is not a new data point; a system that counts it twice
  #   is one where the loudest reader wins.
  #
  # ⚠ THE WEIGHT IS NOT STORED. Only the honest fact — this user said 4 — is.
  #   Weight follows standing, and standing changes: people reach TL2, become
  #   supporters, get suspended. Freezing it at cast time would leave the site
  #   scored by who people used to be. See Curiobase::Standing.
  module VoteStore
    RANGE = (1..5)
    PLUGIN = "curiobase"

    def self.key(work_id, subject) = "votes:#{work_id}:#{subject}"

    # { user_id (Integer) => value } for one pairing.
    #
    # ⚠ PluginStore round-trips through JSON, so the hash comes back with
    #   STRING keys however it went in. Normalising here means nothing
    #   downstream has to remember that.
    def self.raw(work_id:, subject:)
      raw_many([[work_id, subject]]).fetch([work_id.to_s, subject.to_s], {})
    end

    # ══════════════════════════════════════════════════════════════════════════
    # ONE QUERY FOR A WHOLE LIST OF PAIRINGS. THE LAST N+1 IN THE RENDER.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # { [work_id, subject] => { user_id => value } }, string-keyed pairs.
    #
    # ⚠ D-045 batched the records, the posters and the likes and left THIS one,
    #   because a subject with seven works only cost seven extra queries and it
    #   did not show. Profiled at forty works: `plugin_store_rows` was **40 of
    #   the 48 queries** the association list spent — the single thing growing
    #   linearly with the list, on the surface about to render ten times more
    #   rows. Every other per-row cost had already been removed years of
    #   reasoning ago; this was the one nobody re-measured.
    #
    # ⚠ `PluginStore.get_all` is core, so this needs no SQL of its own.
    def self.raw_many(pairs)
      wanted =
        Array(pairs).filter_map do |work_id, subject|
          w = work_id.to_s
          s = subject.to_s
          next if w.blank? || s.blank?
          [key(w, s), [w, s]]
        end.to_h
      return {} if wanted.empty?

      PluginStore
        .get_all(PLUGIN, wanted.keys)
        .each_with_object({}) do |(k, stored), out|
          pair = wanted[k]
          next unless pair && stored.is_a?(Hash)
          out[pair] = normalise(stored)
        end
    end

    # ⚠ ONE IMPLEMENTATION of "a stored blob becomes votes". It ran in `raw` and
    #   would have been copied into the batch — which is exactly how this
    #   codebase produced a check that understood one of the two ways a thing
    #   can exist, seven times.
    def self.normalise(stored)
      stored.each_with_object({}) do |(uid, value), out|
        v = value.to_i
        out[uid.to_i] = v if RANGE.cover?(v)
      end
    end

    def self.cast(work_id:, subject:, user_id:, value:)
      raise ArgumentError, "value out of range" unless RANGE.cover?(value.to_i)

      # ⚠ Read-modify-write on a shared blob. Two members voting on the same
      #   pairing in the same second would otherwise clobber each other, and
      #   the loser would never know — their vote would simply not be there.
      DistributedMutex.synchronize("curiobase:#{key(work_id, subject)}") do
        votes = raw(work_id: work_id, subject: subject)
        votes[user_id.to_i] = value.to_i
        PluginStore.set(PLUGIN, key(work_id, subject), votes)
      end

      value.to_i
    end

    # ⚠ TAKING A VOTE BACK IS A FIRST-CLASS ACT, not an edge case.
    #
    #   "I do not have a view on this any more" is a different statement from
    #   "I think it is a 3", and a scale with no way out forces the second when
    #   someone means the first. Clicking your own mark again retracts it.
    def self.retract(work_id:, subject:, user_id:)
      DistributedMutex.synchronize("curiobase:#{key(work_id, subject)}") do
        votes = raw(work_id: work_id, subject: subject)
        next false unless votes.delete(user_id.to_i)

        # An empty pairing leaves no row behind — otherwise the store fills with
        # keys holding {} and the sweep has more to walk every year.
        votes.empty? ? PluginStore.remove(PLUGIN, key(work_id, subject)) :
          PluginStore.set(PLUGIN, key(work_id, subject), votes)
        true
      end
    end

    def self.for_user(work_id:, subject:, user_id:)
      raw(work_id: work_id, subject: subject)[user_id.to_i]
    end

    # [{ value:, weight: }, ...] — what Gravity averages.
    def self.weighted_votes(work_id:, subject:)
      votes = raw(work_id: work_id, subject: subject)
      return [] if votes.empty?

      weigh(votes, Standing.weights_for(votes.keys))
    end

    # ⚠ The one place a raw vote hash meets a weight table. `Gravity.readings`
    #   fetches both in bulk and calls this directly rather than re-deriving it,
    #   so the batched path and the single path cannot compute different numbers.
    def self.weigh(votes, weights)
      votes.filter_map do |user_id, value|
        weight = weights[user_id].to_f
        next unless weight.positive?
        { value: value, weight: weight }
      end
    end

    # ⚠ NO FOREIGN KEY, so removal is a sweep. PluginStore is a key-value table
    #   and the keys are pairings, not users — the cost of not having a
    #   migration. At this site's scale that is a background job over a few
    #   hundred rows, not a problem; if the catalogue ever reaches a scale where
    #   it is, that is the moment to reconsider the table.
    def self.forget_user(user_id)
      id = user_id.to_i
      PluginStoreRow
        .where(plugin_name: PLUGIN)
        .where("key LIKE 'votes:%'")
        .find_each do |row|
          votes = (JSON.parse(row.value) rescue nil)
          next unless votes.is_a?(Hash)
          next unless votes.key?(id.to_s) || votes.key?(id)
          votes.delete(id.to_s)
          votes.delete(id)
          DistributedMutex.synchronize("curiobase:#{row.key}") do
            votes.empty? ? PluginStore.remove(PLUGIN, row.key) : PluginStore.set(PLUGIN, row.key, votes)
          end
        end
    end
  end
end
