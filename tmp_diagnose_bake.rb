# frozen_string_literal: true

%w[embeds card_renderer google_books post_record].each do |f|
  load "/src/plugins/tti-curiobase/app/services/curiobase/#{f}.rb"
end

[68, 69, 70].each do |id|
  t = Topic.find(id)
  p = t.first_post
  r = Curiobase::PostRecord.parse(p.raw)
  puts "=== #{id} valid=#{r&.valid?} missing=#{r&.missing.inspect} unknown=#{r&.unknown.inspect} ==="
  begin
    Curiobase.rebake_now!(p)
    p.reload
    puts "after: card=#{p.cooked.include?("curiobase-card")} stage=#{p.cooked.include?("cb-stage")} media=#{p.cooked.include?("cb-media-link")} poster-link=#{p.cooked.include?("cb-poster--link")}"
  rescue => e
    puts "rebake boom #{e.class}: #{e.message}"
    puts e.backtrace.first(5)
  end
end
