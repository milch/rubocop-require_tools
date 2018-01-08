require 'bundler/setup'
require 'rubocop/require_tools'

require 'rubocop/rspec/support'

RSpec.configure do |config|
  config.include RuboCop::RSpec::ExpectOffense

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = :random
end
