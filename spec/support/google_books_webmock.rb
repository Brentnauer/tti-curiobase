# frozen_string_literal: true

# Default: Google Books probes must not hit the network during cook.
# Specs that assert probe behaviour register a more specific stub.
RSpec.configure do |config|
  config.before(:each) do
    next unless defined?(WebMock) && defined?(stub_request)

    stub_request(:get, %r{googleapis\.com/books/v1/volumes}).to_return(
      status: 200,
      body: { items: [] }.to_json,
      headers: { "Content-Type" => "application/json" },
    )
  end
end
