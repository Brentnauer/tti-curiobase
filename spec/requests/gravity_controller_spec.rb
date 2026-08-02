# frozen_string_literal: true

require "rails_helper"

# The endpoint is the only writable surface this plugin exposes. Almost
# everything here is about what it REFUSES.
RSpec.describe Curiobase::GravityController do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:other_tag) { Fabricate(:tag, name: "funny") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }
  fab!(:topic)
  # ⚠ Not `fab!(:post)` — that shadows the `post` request helper and every
  #   request in this file fails with "wrong number of arguments".
  fab!(:op) { Fabricate(:post, topic: topic, raw: "[wrap=work id=123]\n[/wrap]") }
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[1]) }

  before do
    SiteSetting.curiobase_enabled = true
    # ⚠ Endpoint 404s when voting is closed — see the last example in this file.
    SiteSetting.curiobase_member_voting_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    SiteSetting.curiobase_min_trust_level = 1
    Curiobase::Subjects.reset_cache!
    topic.tags = [tag, other_tag]
    FileUtils.rm_f(Rails.root.join("tmp", "curiobase-votes.json"))
  end

  def cast(**params)
    post_json = { topic_id: topic.id, subject: "causal-loop" }.merge(params)
    post "/curiobase/gravity.json", params: post_json
  end

  it "refuses when signed out" do
    cast(value: 4)
    expect(response.status).to eq(403)
  end

  context "signed in" do
    before { sign_in(user) }

    it "accepts a rating in range" do
      cast(value: 4)
      expect(response.status).to eq(200)
      expect(response.parsed_body["mine"]).to eq(4)
    end

    # ⚠ Subject association lists are baked into the Subject file. A vote that
    #   only rebaked the Work left those lists stale. Both topics are throttled
    #   independently (≤1 rebake/minute each).
    it "schedules a throttled rebake of the Work and the Subject file" do
      subject_topic = Fabricate(:topic, title: "Causal Loop, the file", user: Fabricate(:admin), tags: [tag])
      subject_op =
        Fabricate(
          :post,
          topic: subject_topic,
          user: subject_topic.user,
          raw: <<~RAW,
            ```curiobase
            type: subject
            slug: causal-loop
            kind: idea
            domain: time
            dek: When an effect is among its own causes.
            ```
          RAW
        )
      Curiobase.rebake_now!(subject_op)
      Discourse.redis.del("curiobase:rebake:#{topic.id}")
      Discourse.redis.del("curiobase:rebake:#{subject_topic.id}")

      expect_enqueued_with(job: :curiobase_rebake, args: { post_id: op.id }) do
        expect_enqueued_with(job: :curiobase_rebake, args: { post_id: subject_op.id }) do
          cast(value: 4)
        end
      end
      expect(response.status).to eq(200)
    end

    # ⚠ The response must carry the number the card will bake a minute later,
    #   computed the same way. Returning anything else makes the row jump back
    #   on rebake and readers conclude their vote was thrown away.
    it "answers with the number the card will show" do
      cast(value: 1)
      # One TL1 vote, alone in the average.
      expect(response.parsed_body["display"]).to eq(1.0)
      expect(response.parsed_body["voter_count"]).to eq(1)
      # ⚠ No bar from a single voter.
      expect(response.parsed_body["distribution"]).to be_nil
    end

    # Open Subject tabs repaint association gravity without waiting on cooked.
    it "publishes the reading on the subject MessageBus channel" do
      messages = MessageBus.track_publish("/curiobase/subject/causal-loop") { cast(value: 4) }
      expect(response.status).to eq(200)
      expect(messages.length).to eq(1)
      data = messages.first.data
      data = JSON.parse(data) if data.is_a?(String)
      data = data.with_indifferent_access if data.respond_to?(:with_indifferent_access)
      # Wrap id=123 resolves through Source to the primer fixture (slug key).
      expect(data[:work_id]).to eq("primer-2004")
      expect(data[:display]).to eq(4.0)
      expect(data[:voter_count]).to eq(1)
    end

    it "averages a staff vote equally with a member's" do
      sign_in(Fabricate(:admin))
      cast(value: 5)
      sign_in(user)
      cast(value: 1)

      expect(response.parsed_body["display"]).to eq(3.0)
      expect(response.parsed_body["voter_count"]).to eq(2)
      expect(response.parsed_body["distribution"]).to eq([1, 0, 0, 0, 1])
    end

    # Changing your mind is not a new data point.
    it "replaces rather than accumulates" do
      cast(value: 1)
      first = response.parsed_body["voter_count"]
      cast(value: 5)
      expect(response.parsed_body["voter_count"]).to eq(first)
      expect(response.parsed_body["mine"]).to eq(5)
    end

    describe "taking a vote back" do
      def retract
        delete "/curiobase/gravity.json", params: { topic_id: topic.id, subject: "causal-loop" }
      end

      it "clears the member's vote and the score with it" do
        cast(value: 4)
        retract

        expect(response.status).to eq(200)
        expect(response.parsed_body["mine"]).to be_nil
        # ⚠ The last vote leaving takes the pairing back to unrated. The client
        #   has to be told that, or it leaves a stale number on a row with
        #   nothing behind it.
        expect(response.parsed_body["display"]).to be_nil
        expect(response.parsed_body["voter_count"]).to eq(0)
      end

      it "leaves everybody else's votes alone" do
        other = Fabricate(:user, trust_level: TrustLevel[1])
        Curiobase::VoteStore.cast(
          work_id: "primer-2004", subject: "causal-loop", user_id: other.id, value: 2,
        )

        cast(value: 5)
        retract

        expect(response.parsed_body["display"]).to eq(2.0)
        expect(response.parsed_body["voter_count"]).to eq(1)
      end

      # ⚠ No trust check and no rate limit on the way out. Someone who has hit
      #   the hourly cap must still be able to undo the last thing they did.
      it "works even when the caller is rate limited" do
        cast(value: 4)
        RateLimiter.new(user, "curiobase-gravity", 0, 1.hour).performed! rescue nil
        retract
        expect(response.status).to eq(200)
      end
    end

    it "404s when member voting is closed" do
      SiteSetting.curiobase_member_voting_enabled = false
      cast(value: 4)
      expect(response.status).to eq(404)
    end

    it "refuses a value outside 1-5" do
      cast(value: 9)
      expect(response.status).to eq(422)
    end

    # ⚠ THE CLIENT DOES NOT GET TO SAY WHAT IT IS RATING. The work id comes off
    #   the topic's own wrap, and the subject must be a tag on that topic AND in
    #   the synced vocabulary. Otherwise a browser could write rows for pairings
    #   nobody ever created.
    it "refuses a subject that is not a tag on the topic" do
      cast(subject: "temporal-perception", value: 4)
      expect(response.status).to eq(400)
    end

    it "refuses a tag outside the subject vocabulary" do
      cast(subject: "funny", value: 4)
      expect(response.status).to eq(400)
    end

    it "refuses a topic that is not a work record" do
      plain = Fabricate(:topic)
      Fabricate(:post, topic: plain, raw: "no wrap here")
      plain.tags = [tag]
      post "/curiobase/gravity.json", params: { topic_id: plain.id, subject: "causal-loop", value: 4 }
      expect(response.status).to eq(400)
    end

    it "refuses below the trust level" do
      SiteSetting.curiobase_min_trust_level = 3
      cast(value: 4)
      expect(response.status).to eq(403)
    end

    it "404s when the plugin is off" do
      SiteSetting.curiobase_enabled = false
      cast(value: 4)
      expect(response.status).to eq(404)
    end
  end
end
