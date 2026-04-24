require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
  primary_coverage :line
  minimum_coverage line: 100
  # Give each parallel worker a unique command name so results are merged
  command_name "Rails Tests"
  # Exclude browser-dependent harvester (requires Chrome + 2Captcha API key)
  add_filter "app/services/public_contracts/pt/registo_comercial_harvester.rb"
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Merge SimpleCov results across parallel workers
    parallelize_setup do |worker|
      SimpleCov.command_name "#{SimpleCov.command_name} (worker #{worker})"
    end

    parallelize_teardown do |_worker|
      SimpleCov.result
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
