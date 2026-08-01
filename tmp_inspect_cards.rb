# frozen_string_literal: true

[66, 67, 68, 69, 70, 71].each do |id|
  t = Topic.find_by(id: id)
  if t.nil?
    puts "missing #{id}"
    next
  end
  c = t.first_post.cooked
  puts "=== #{id} #{t.slug} ==="
  puts "stage=#{c.include?("cb-stage")} iframe=#{c.include?("iframe")} media=#{c.include?("cb-media-link")} poster=#{c.include?("cb-poster")} empty=#{c.include?("cb-poster--empty")}"
  puts c[0, 500].gsub(/\s+/, " ")
  puts
end
