# frozen_string_literal: true

module Curiobase
  # The poster, dragged into the composer like any other image.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # THE ORDER OF post_process IS WHAT MAKES THIS WORK.
  # ══════════════════════════════════════════════════════════════════════════
  #
  #   CookedPostProcessor#post_process runs, in this order:
  #
  #     post_process_images          resolves upload:// and sizes the img
  #     optimize_urls                rewrites to the CDN if one is configured
  #     link_post_uploads            attaches the upload to the post
  #     trigger(:post_process_cooked)  ← we are here
  #
  #   So by the time the card is built the image is already a finished <img>
  #   with a real src, real dimensions, and an upload row behind it. There is no
  #   upload code to write. There is only a node to move.
  #
  # ⚠ THIS IS BETTER THAN THE WORDPRESS PATH, not merely equivalent. A poster in
  #   the CMS is served from cms.timetravelinstitute.com, so every record image
  #   on the public forum is a live cross-origin dependency on a staff system —
  #   if it is down, slow or rate-limited, posters break on a page that is
  #   otherwise fine. Discourse-hosted media removes that entirely, and picks up
  #   the site's CDN, size rules and secure-upload handling on the way past.
  class PostMedia
    # ══════════════════════════════════════════════════════════════════════════
    # THE ASPECT RATIO IS THE TYPE SIGNAL.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Portrait means somebody made this. Landscape means this happened, or
    # exists. A reader can tell a Work from a Subject without reading a word,
    # which is most of what "it should look different but still be useful" was
    # asking for — and it costs nothing, because both are one CSS rule and one
    # variant size.
    #
    #   POSTER  2:3   a Work. Film poster, book cover, box art
    #   PLATE   3:2   a Subject. A photograph of the thing or the place
    #
    # ⚠ 3:2, NOT 16:9. 3:2 is the native shape of photography, so archival
    #   material crops gracefully. 16:9 is a video shape and slices the top and
    #   bottom off anything older than a camcorder.
    VARIANTS = {
      poster: [520, 780].freeze,
      plate: [1200, 800].freeze,
    }.freeze

    # ⚠ THE VARIANT COMES FROM THE RECORD, NOT FROM THE IMAGE.
    #
    #   This used to be `upload.width > upload.height ? HERO : POSTER` — it
    #   picked the shape by looking at whatever the author happened to drag in.
    #   So a landscape film still on a Work got hero treatment and a portrait
    #   photograph on a Subject got poster treatment, which is exactly backwards:
    #   the whole point is that the shape tells you what KIND of record this is.
    #   The source image is cropped to fit, not consulted about it.
    def initialize(doc, post, variant: :poster)
      @doc = doc
      @post = post
      @variant = VARIANTS.key?(variant) ? variant : :poster
    end

    # Pulls the first real image out of the body and hands back a node ready to
    # place in the card. Returns nil when the author has not added one.
    #
    # ⚠ REMOVES IT FROM WHERE IT WAS. The card is the rendered post, so leaving
    #   the original behind shows the image twice.
    def take!
      img = @doc.css("img").find { |i| candidate?(i) }
      return nil unless img

      upload = upload_for(img)
      claim!(upload)

      figure = Nokogiri::XML::Node.new("div", @doc.document)
      figure["class"] = "cb-#{@variant}"

      out = img.dup
      out.remove_attribute("width")
      out.remove_attribute("height")
      if (sized = optimized(upload))
        out["src"] = sized.url
        out["width"] = sized.width.to_s
        out["height"] = sized.height.to_s
      end
      out["loading"] = "lazy"
      out["alt"] = img["alt"].presence || ""

      figure.add_child(out)
      # ⚠ Take the whole wrapper Discourse built, not just the img — a bare
      #   <a class="lightbox"> left behind renders as an empty link.
      (img.ancestors(".lightbox-wrapper").first || img).remove
      @src = out["src"]
      figure
    end

    # The URL that ended up in the card, so CardRenderer can cache it on the
    # topic. Only meaningful after take!.
    attr_reader :src

    private

    # Emoji and avatars are <img> too.
    def candidate?(img)
      return false if img["class"].to_s.match?(/emoji|avatar|site-icon/)
      return false if img["src"].blank?
      true
    end

    def upload_for(img)
      # Discourse leaves the id on the node once it has processed the image.
      id = img["data-base62-sha1"]
      id ? Upload.find_by(sha1: Upload.sha1_from_base62_encoded(id)) : nil
    rescue StandardError
      nil
    end

    # ⚠ CLAIM IT, OR THE REAPER TAKES IT.
    #
    #   Jobs::CleanUpUploads deletes any upload with no row in
    #   upload_references. Discourse's own link_post_uploads has already made
    #   one pointing at the post, so this is belt and braces — but if a record
    #   ever stops being a post, this line is what stops the posters vanishing.
    #   discourse-calendar does exactly this for event images.
    def claim!(upload)
      return unless upload && @post&.topic
      UploadReference.ensure_exist!(upload_ids: [upload.id], target: @post.topic)
    rescue StandardError => e
      Rails.logger.warn("[curiobase] could not claim upload #{upload&.id}: #{e.class}")
    end

    # ⚠ Generated on demand and cached by Discourse. A 4MB poster off a desktop
    #   becomes a sensible file without anyone thinking about it — which is the
    #   whole reason a media library felt necessary.
    #
    # ⚠ Only ever shrinks. `[upload.width, w].min` means a small image is served
    #   at its own size rather than upscaled into a blurry one; the CSS crops it
    #   to the ratio either way.
    def optimized(upload)
      return nil unless upload&.width && upload&.height
      w, h = VARIANTS[@variant]
      return nil if upload.width <= w && upload.height <= h
      OptimizedImage.create_for(upload, [upload.width, w].min, [upload.height, h].min)
    rescue StandardError => e
      Rails.logger.warn("[curiobase] optimise failed for #{upload&.id}: #{e.class}")
      nil
    end
  end
end
