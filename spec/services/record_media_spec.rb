# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# THE ASPECT RATIO IS THE TYPE SIGNAL.
# ══════════════════════════════════════════════════════════════════════════════
#
# Portrait means somebody made this. Landscape means it happened, or exists. A
# reader tells a Work from a Subject before reading a word — so the shape has to
# come from the RECORD, never from whatever the author happened to drag in.
RSpec.describe "record media" do
  fab!(:admin) { Fabricate(:admin) }

  before { SiteSetting.curiobase_enabled = true }

  def doc(html) = Nokogiri::HTML5.fragment(html)

  describe Curiobase::PostMedia do
    fab!(:portrait) { Fabricate(:image_upload, width: 800, height: 1200) }
    fab!(:landscape) { Fabricate(:image_upload, width: 2000, height: 1333) }
    fab!(:topic) { Fabricate(:topic, title: "Primer, the garage film about loops") }
    fab!(:post) do
      Fabricate(:post, topic: topic, post_number: 1, raw: "A post long enough to satisfy Discourse.")
    end

    # ⚠ THE BUG THIS REPLACED. The variant was picked by
    #   `upload.width > upload.height`, so a landscape film still on a Work got
    #   hero treatment and a portrait photograph on a Subject got poster
    #   treatment — exactly backwards.
    it "gives a Work the poster class whatever shape the source image is" do
      %w[portrait landscape].each do |which|
        up = send(which)
        d = doc(%(<img src="#{up.url}">))
        fig = described_class.new(d, post, variant: :poster).take!

        expect(fig["class"]).to eq("cb-poster"), "#{which} source produced #{fig["class"]}"
      end
    end

    it "gives a Subject the plate class whatever shape the source image is" do
      %w[portrait landscape].each do |which|
        up = send(which)
        d = doc(%(<img src="#{up.url}">))
        fig = described_class.new(d, post, variant: :plate).take!

        expect(fig["class"]).to eq("cb-plate"), "#{which} source produced #{fig["class"]}"
      end
    end

    it "falls back to the poster shape rather than raising on an unknown variant" do
      d = doc(%(<img src="#{portrait.url}">))
      expect(described_class.new(d, post, variant: :nonsense).take!["class"]).to eq("cb-poster")
    end

    it "exposes the src it settled on, so the renderer can cache it" do
      d = doc(%(<img src="#{portrait.url}">))
      m = described_class.new(d, post, variant: :poster)
      m.take!

      expect(m.src).to be_present
    end

    # ⚠ Only ever shrinks. A small image served at its own size beats a blurry
    #   upscale; the CSS crops it to the ratio either way.
    it "does not upscale an image smaller than the variant" do
      small = Fabricate(:image_upload, width: 120, height: 180)
      d = doc(%(<img src="#{small.url}">))
      expect(OptimizedImage).not_to receive(:create_for)

      described_class.new(d, post, variant: :poster).take!
    end
  end

  # ── on a real card ──────────────────────────────────────────────────────────
  describe "on a rendered card" do
    fab!(:upload) { Fabricate(:image_upload, width: 900, height: 1350) }

    def bake!(title, body, with_image: true)
      topic = Fabricate(:topic, title: title, user: admin)
      raw = +"```curiobase\n#{body}\n```"
      raw << "\n\n![cover|900x1350](#{upload.short_url})" if with_image
      post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: raw)
      Curiobase.rebake_now!(post)
      [topic.reload, post.reload]
    end

    let(:work) do
      "type: work\nslug: primer-2004\nmedium: film\nyear: 2004\ndek: Two engineers build a box."
    end

    it "puts the poster in the Work's head" do
      _, post = bake!("Primer, the garage film about loops", work)
      expect(post.cooked).to include("cb-poster")
      expect(post.cooked).not_to include("cb-plate")
    end

    # ⚠ Reserve the slot. An empty column means the text starts at a different x
    #   on every card without a cover, and a run of them reads as broken.
    it "reserves the slot with a typographic placeholder when there is no cover" do
      _, post = bake!("Primer, the garage film about loops", work, with_image: false)
      frag = Nokogiri::HTML5.fragment(post.cooked)

      expect(frag.at_css(".cb-poster--empty")).to be_present
      expect(frag.at_css(".cb-poster-label").text).to include("film").and include("2004")
    end

    it "caches the poster url on the topic so the association list need not open the post" do
      topic, = bake!("Primer, the garage film about loops", work)
      expect(topic.custom_fields[Curiobase::CardRenderer::POSTER_FIELD]).to be_present
    end

    # ── the plate ─────────────────────────────────────────────────────────────
    let(:subject_record) do
      "type: subject\nslug: rendlesham-forest\nkind: incident\ndomain: contact\n" \
        "image_credit: RAF Woodbridge east gate, 1983 · USAF, public domain\n" \
        "dek: Three nights in December 1980."
    end

    it "puts the plate on the Subject, not a poster" do
      _, post = bake!("Rendlesham Forest, three nights in 1980", subject_record)
      expect(post.cooked).to include("cb-plate")
      expect(post.cooked).not_to include("cb-poster")
    end

    # ⚠ AFTER THE DEK, always. The dek leads the DOM for the search snippet and
    #   that rule has regressed three times.
    it "places the plate after the dek in document order" do
      _, post = bake!("Rendlesham Forest, three nights in 1980", subject_record)
      frag = Nokogiri::HTML5.fragment(post.cooked)
      order = frag.css(".cb-dek, .cb-plate-figure").map { |n| n["class"].split.first }

      expect(order.first).to eq("cb-dek")
    end

    # ⚠ The caption is what makes it a plate rather than a picture. A Work's
    #   poster is the artifact; a Subject's image is evidence.
    it "captions the plate with the credit" do
      _, post = bake!("Rendlesham Forest, three nights in 1980", subject_record)
      expect(post.cooked).to include("cb-plate-credit").and include("RAF Woodbridge east gate")
    end

    it "renders the plate with no caption when no credit is given" do
      _, post = bake!(
        "Rendlesham Forest, three nights in 1980",
        "type: subject\nslug: rendlesham-forest\nkind: incident\ndomain: contact\ndek: Three nights.",
      )
      expect(post.cooked).to include("cb-plate")
      expect(post.cooked).not_to include("cb-plate-credit")
    end

    it "accepts image_credit through the validator and round-trips it" do
      raw = "```curiobase\n#{subject_record}\n```"
      expect(Curiobase::RecordValidator.errors_for(raw)).to be_empty

      parsed = Curiobase::PostRecord.parse(raw)
      record = Curiobase::PostRecord.to_record(parsed)
      expect(record["image_credit"]).to include("public domain")
      expect(Curiobase::RecordWriter.losses(record)).to be_empty
    end
  end

  # ── the association list ────────────────────────────────────────────────────
  describe "thumbnails on a Subject's list" do
    fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
    fab!(:upload) { Fabricate(:image_upload, width: 900, height: 1350) }
    fab!(:work_topic) { Fabricate(:topic, title: "Primer (2004), the garage film") }

    before do
      claim_subject_file!("causal-loop")
      post = Fabricate(:post, topic: work_topic, user: admin, post_number: 1, raw: <<~RAW)
        ```curiobase
        type: work
        slug: primer-2004
        medium: film
        dek: Two engineers build a box.
        ```

        ![cover|900x1350](#{upload.short_url})
      RAW
      Curiobase.rebake_now!(post)
      work_topic.tags = [tag]
    end

    it "carries the cached poster onto the row" do
      row = Curiobase::Associations.new("causal-loop").rows.find { |r| r.kind == "work" }
      expect(row.poster).to be_present
    end

    # ⚠ ONE QUERY, not one per row. A Subject with 25 Works must not open 25
    #   posts to find 25 images — that is the N+1 RecordTopic exists to avoid.
    it "reads every poster in a single query" do
      n = 0
      sub = ->(*, **) { n += 1 }
      ActiveSupport::Notifications.subscribed(sub, "sql.active_record") do
        Curiobase::Associations.new("causal-loop").rows
      end

      poster_queries = 0
      counter = ->(_, _, _, _, payload) do
        poster_queries += 1 if payload[:sql].to_s.include?(Curiobase::CardRenderer::POSTER_FIELD)
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        Curiobase::Associations.new("causal-loop").rows
      end

      expect(poster_queries).to be <= 1
    end

    # ⚠ ALL OR NOTHING PER LIST. Once ANY row has a cover, every row reserves a
    #   cell so the titles stay aligned.
    it "emits a thumb cell on every row once any row has a cover" do
      html = Curiobase::SubjectCard.for_slug("causal-loop")&.to_html
      frag = Nokogiri::HTML5.fragment(html.to_s)

      expect(frag.at_css(".cb-assoc-list")["class"]).to include("cb-assoc-list--thumbs")
      expect(frag.css(".cb-assoc-row").size).to eq(frag.css(".cb-assoc-thumb").size)
    end

    # ⚠ And no column at all when nothing in the list has one — a column of
    #   empty grey boxes reads as broken rather than as incomplete, and spends
    #   width on nothing. This is the state every list is in until posters are
    #   added, so it is the one that has to look deliberate.
    it "drops the thumb column entirely when no row has a cover" do
      work_topic.custom_fields[Curiobase::CardRenderer::POSTER_FIELD] = nil
      work_topic.save_custom_fields

      frag = Nokogiri::HTML5.fragment(Curiobase::SubjectCard.for_slug("causal-loop").to_html)

      expect(frag.at_css(".cb-assoc-list")["class"]).not_to include("--thumbs")
      expect(frag.css(".cb-assoc-thumb")).to be_empty
      expect(frag.css(".cb-assoc-row")).not_to be_empty
    end

    # ⚠ The kind is an eyebrow ABOVE the title now, not a column beside it —
    #   `[thumb] BOOK The Voynich Manuscript (2016)` was three things racing
    #   across one line for width the title needed.
    it "puts the kind as an eyebrow inside the title block" do
      frag = Nokogiri::HTML5.fragment(Curiobase::SubjectCard.for_slug("causal-loop").to_html)
      main = frag.at_css(".cb-assoc-row .cb-assoc-main")

      expect(main.at_css(".cb-assoc-kind")).to be_present
      expect(main.at_css(".cb-assoc-title")).to be_present
      expect(main.children.first["class"]).to include("cb-assoc-kind")
    end

    # ⚠ Title on the banner, not a plate thumbnail — the tag page names the
    #   Subject and points at the record; the plate stays on the file topic.
    it "names the Subject on the banner and omits any plate thumb" do
      html = Curiobase::SubjectCard.for_slug("causal-loop", variant: :banner)&.to_html.to_s
      expect(html).to include("cb-banner-title")
      expect(html).to include("Causal Loop")
      expect(html).not_to include("cb-plate")
      expect(html).not_to include("cb-banner-thumb")
    end
  end
end
