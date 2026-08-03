# frozen_string_literal: true

require "rspec"
require "tmpdir"
require "fileutils"
require "json"
require "tempfile"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "session_memory"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
