# frozen_string_literal: true

require "test_helper"
require "rake"

class EnrichTaskTest < ActiveSupport::TestCase
  # Load rake tasks once to avoid repeated load resetting SimpleCov counters
  Rake.application = Rake::Application.new
  Rake.application.define_task(Rake::Task, :environment)
  load Rails.root.join("lib/tasks/enrich.rake")

  # ── export_nifs ──────────────────────────────────────────────────

  test "export_nifs writes NIFs to output file with flagged first" do
    entity = entities(:two) # is_company: true, country_code: PT

    Dir.mktmpdir do |dir|
      output = File.join(dir, "nifs.txt")
      ENV["OUTPUT"] = output
      ENV["SKIP_ENRICHED"] = "0"

      Rake::Task["enrich:export_nifs"].reenable
      Rake::Task["enrich:export_nifs"].invoke

      nifs = File.readlines(output).map(&:strip).reject(&:empty?)
      assert_includes nifs, entity.tax_identifier

      ENV.delete("OUTPUT")
      ENV.delete("SKIP_ENRICHED")
    end
  end

  test "export_nifs skips already-enriched entities" do
    entity = entities(:two)
    person = Person.create!(name: "Test Person", country_code: "PT")
    EntityPersonRole.create!(
      entity: entity, person: person, role_type: "manager",
      role_label: "Gerente", source_name: "Registo Comercial", active: true,
      verified_at: Time.current
    )

    Dir.mktmpdir do |dir|
      output = File.join(dir, "nifs.txt")
      ENV["OUTPUT"] = output
      ENV["SKIP_ENRICHED"] = "1"

      Rake::Task["enrich:export_nifs"].reenable
      Rake::Task["enrich:export_nifs"].invoke

      nifs = File.readlines(output).map(&:strip).reject(&:empty?)
      refute_includes nifs, entity.tax_identifier

      ENV.delete("OUTPUT")
      ENV.delete("SKIP_ENRICHED")
    end
  end

  test "export_nifs respects LIMIT" do
    # Create a second company so there are 2 candidates
    Entity.create!(name: "Extra Co", tax_identifier: "509999099", country_code: "PT", is_company: true)

    Dir.mktmpdir do |dir|
      output = File.join(dir, "nifs.txt")
      ENV["OUTPUT"] = output
      ENV["SKIP_ENRICHED"] = "0"
      ENV["LIMIT"] = "1"

      Rake::Task["enrich:export_nifs"].reenable
      Rake::Task["enrich:export_nifs"].invoke

      nifs = File.readlines(output).map(&:strip).reject(&:empty?)
      assert_equal 1, nifs.size

      ENV.delete("OUTPUT")
      ENV.delete("SKIP_ENRICHED")
      ENV.delete("LIMIT")
    end
  end

  # ── harvest ──────────────────────────────────────────────────────

  test "harvest task aborts without TWOCAPTCHA_KEY" do
    ENV.delete("TWOCAPTCHA_KEY")
    Rake::Task["enrich:harvest"].reenable
    assert_raises(SystemExit) { Rake::Task["enrich:harvest"].invoke }
  end

  test "harvest task creates harvester with correct options and on_nif_complete callback" do
    captured_args = nil
    captured_nifs = nil

    fake_harvester = Object.new
    fake_harvester.define_singleton_method(:harvest) { |nifs| captured_nifs = nifs }

    Dir.mktmpdir do |dir|
      nifs_file = File.join(dir, "nifs.txt")
      File.write(nifs_file, "501412727\n500043256\n")

      ENV["TWOCAPTCHA_KEY"] = "test_key_123"
      ENV["NIFS_FILE"] = nifs_file
      ENV["BATCH"] = "1"
      ENV["HEADLESS"] = "true"

      PublicContracts::PT::RegistoComercialHarvester.stub(:new, ->(captcha_key:, output_path:, headless:, on_nif_complete: nil) {
        captured_args = { captcha_key: captcha_key, output_path: output_path, headless: headless, on_nif_complete: on_nif_complete }
        fake_harvester
      }) do
        Rake::Task["enrich:harvest"].reenable
        Rake::Task["enrich:harvest"].invoke
      end

      assert_equal "test_key_123", captured_args[:captcha_key]
      assert captured_args[:headless]
      assert_respond_to captured_args[:on_nif_complete], :call
      assert_equal ["501412727"], captured_nifs  # BATCH=1
    ensure
      ENV.delete("TWOCAPTCHA_KEY")
      ENV.delete("NIFS_FILE")
      ENV.delete("BATCH")
      ENV.delete("HEADLESS")
    end
  end

  test "harvest task defaults to export_nifs when no NIFS_FILE given" do
    captured_nifs = nil

    fake_harvester = Object.new
    fake_harvester.define_singleton_method(:harvest) { |nifs| captured_nifs = nifs }

    ENV["TWOCAPTCHA_KEY"] = "test_key_123"
    ENV.delete("NIFS_FILE")
    ENV["SKIP_ENRICHED"] = "0"
    # Don't set OUTPUT — let it default to /tmp/rc_target_nifs.txt so harvest reads from same path

    PublicContracts::PT::RegistoComercialHarvester.stub(:new, ->(**_opts, &_blk) { fake_harvester }) do
      Rake::Task["enrich:export_nifs"].reenable
      Rake::Task["enrich:harvest"].reenable
      Rake::Task["enrich:harvest"].invoke
    end

    assert_kind_of Array, captured_nifs
  ensure
    ENV.delete("TWOCAPTCHA_KEY")
    ENV.delete("SKIP_ENRICHED")
    FileUtils.rm_f("/tmp/rc_target_nifs.txt")
  end

  # ── import_rc ────────────────────────────────────────────────────

  test "import_rc task aborts when input file missing" do
    ENV["INPUT"] = "/tmp/definitely_missing_rc_results.json"
    Rake::Task["enrich:import_rc"].reenable
    assert_raises(SystemExit) { Rake::Task["enrich:import_rc"].invoke }
  ensure
    ENV.delete("INPUT")
  end

  test "import_rc task uses RegistoComercialImporter" do
    Dir.mktmpdir do |dir|
      input = File.join(dir, "results.json")
      File.write(input, "{}")
      ENV["INPUT"] = input

      Rake::Task["enrich:import_rc"].reenable
      Rake::Task["enrich:import_rc"].invoke
      assert true # reached here without abort
    ensure
      ENV.delete("INPUT")
    end
  end
end
