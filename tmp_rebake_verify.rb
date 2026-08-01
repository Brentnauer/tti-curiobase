# frozen_string_literal: true

%w[embeds card_renderer google_books].each do |f|
  load "/src/plugins/tti-curiobase/app/services/curiobase/#{f}.rb"
end

[65, 66, 67, 68, 69, 70, 71].each do |id|
  t = Topic.find_by(id: id)
  if t.nil?
    puts "missing #{id}"
    next
  end

  p = t.first_post
  Curiobase.rebake_now!(p)
  c = p.reload.cooked
  has_stage = c.include?("cb-stage")
  has_iframe = c.include?("youtube.com/embed")
  has_media = c.include?("cb-media-link")
  has_onebox = c.include?("aside.onebox") || c.include?('class="onebox"')
  has_yt_ext = c.include?(">YouTube</a>")
  puts "=== #{id} #{t.slug} ==="
  puts "stage=#{has_stage} iframe=#{has_iframe} media-link=#{has_media} onebox=#{has_onebox} youtube-ext=#{has_yt_ext}"
end
