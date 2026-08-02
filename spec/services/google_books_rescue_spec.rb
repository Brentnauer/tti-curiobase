# frozen_string_literal: true

require "rails_helper"

RSpec.describe "google books rescue" do
  it "does not raise when WebMock blocks the probe" do
    expect {
      Curiobase::GoogleBooks.volume_id_for("external" => { "isbn" => "9781591964360" })
    }.not_to raise_error
  end
end
