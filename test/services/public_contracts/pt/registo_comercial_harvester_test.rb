# frozen_string_literal: true

require "test_helper"

class PublicContracts::PT::RegistoComercialHarvesterTest < ActiveSupport::TestCase
  setup do
    @output_path = File.join(Dir.tmpdir, "rc_test_#{SecureRandom.hex(4)}.json")
    @harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key_abc123",
      output_path: @output_path,
      headless: true
    )
  end

  teardown do
    File.delete(@output_path) if File.exist?(@output_path)
  end

  # ── initialization ─────────────────────────────────────────────

  test "initialize sets captcha key and output path" do
    assert_equal({}, @harvester.results)
  end

  test "initialize loads existing results from file" do
    File.write(@output_path, JSON.generate("500043256" => { "totalResults" => 5, "rows" => [], "publications" => [] }))

    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key",
      output_path: @output_path
    )
    assert_equal 5, harvester.results["500043256"]["totalResults"]
  end

  test "initialize handles corrupt JSON gracefully" do
    File.write(@output_path, "not json{{{")

    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key",
      output_path: @output_path
    )
    assert_equal({}, harvester.results)
  end

  # ── skip? ──────────────────────────────────────────────────────

  test "skip? returns false for unknown NIF" do
    assert_equal false, @harvester.send(:skip?, "999999999")
  end

  test "skip? returns false for NIF with error" do
    @harvester.results["999999999"] = { "error" => "search_failed" }
    assert_equal false, @harvester.send(:skip?, "999999999")
  end

  test "skip? returns true for NIF with positive results" do
    @harvester.results["999999999"] = { "totalResults" => 5, "rows" => [], "publications" => [] }
    assert @harvester.send(:skip?, "999999999")
  end

  test "skip? returns true for NIF with zero results (already searched)" do
    @harvester.results["999999999"] = { "totalResults" => 0, "rows" => [], "publications" => [] }
    assert @harvester.send(:skip?, "999999999")
  end

  # ── persistence ────────────────────────────────────────────────

  test "save_results writes JSON to output path" do
    @harvester.results["501412727"] = { "totalResults" => 3, "rows" => [], "publications" => [] }
    @harvester.send(:save_results)

    data = JSON.parse(File.read(@output_path))
    assert_equal 3, data["501412727"]["totalResults"]
  end

  test "load_results returns empty hash when file does not exist" do
    assert_equal({}, @harvester.send(:load_results))
  end

  # ── captcha_balance ────────────────────────────────────────────

  test "captcha_balance makes HTTP request to 2captcha" do
    stub_request = ->(url) {
      assert_includes url, "2captcha.com"
      assert_includes url, "getbalance"
      "3.50"
    }

    @harvester.stub(:http_get, stub_request) do
      assert_equal "3.50", @harvester.send(:captcha_balance)
    end
  end

  test "captcha_balance returns error message on failure" do
    @harvester.stub(:http_get, ->(_url) { raise "connection refused" }) do
      result = @harvester.send(:captcha_balance)
      assert_includes result, "connection refused"
    end
  end

  test "ensure_captcha_balance raises when balance is zero" do
    @harvester.stub(:captcha_balance, "0") do
      error = assert_raises(PublicContracts::PT::RegistoComercialHarvester::CaptchaBalanceError) do
        @harvester.send(:ensure_captcha_balance!)
      end

      assert_includes error.message, "top up and rerun"
      assert_includes error.message, @output_path
    end
  end

  # ── solve_captcha ──────────────────────────────────────────────

  test "solve_captcha submits to 2captcha and polls for result" do
    call_count = 0
    http_stub = ->(_url) {
      call_count += 1
      if call_count == 1
        # Submit response
        '{"status":1,"request":"12345"}'
      else
        # Poll response (ready on first poll)
        '{"status":1,"request":"solved_token_abc"}'
      end
    }

    @harvester.stub(:http_get, http_stub) do
      @harvester.stub(:sleep, nil) do
        token = @harvester.send(:solve_captcha)
        assert_equal "solved_token_abc", token
      end
    end
  end

  test "solve_captcha raises on submit error" do
    @harvester.stub(:http_get, ->(_url) { '{"status":0,"request":"ERROR_KEY_DOES_NOT_EXIST"}' }) do
      assert_raises(RuntimeError, /2Captcha submit error/) do
        @harvester.send(:solve_captcha)
      end
    end
  end

  test "solve_captcha raises a resume-friendly error on zero balance submit response" do
    @harvester.stub(:captcha_balance, "1.25") do
      @harvester.stub(:http_get, ->(_url) { '{"status":0,"request":"ERROR_ZERO_BALANCE"}' }) do
        error = assert_raises(PublicContracts::PT::RegistoComercialHarvester::CaptchaBalanceError) do
          @harvester.send(:solve_captcha)
        end

        assert_includes error.message, "top up and rerun"
        assert_includes error.message, @output_path
      end
    end
  end

  test "solve_captcha raises on poll error" do
    call_count = 0
    http_stub = ->(_url) {
      call_count += 1
      if call_count == 1
        '{"status":1,"request":"12345"}'
      else
        '{"status":0,"request":"ERROR_CAPTCHA_UNSOLVABLE"}'
      end
    }

    @harvester.stub(:http_get, http_stub) do
      @harvester.stub(:sleep, nil) do
        assert_raises(RuntimeError, /2Captcha error/) do
          @harvester.send(:solve_captcha)
        end
      end
    end
  end

  # ── http_get ───────────────────────────────────────────────────

  test "http_get makes HTTPS request and returns body" do
    fake_response = Minitest::Mock.new
    fake_response.expect :body, "response_body"

    fake_http = Minitest::Mock.new
    fake_http.expect :use_ssl=, nil, [true]
    fake_http.expect :open_timeout=, nil, [15]
    fake_http.expect :read_timeout=, nil, [30]
    fake_http.expect :get, fake_response, [String]

    Net::HTTP.stub(:new, fake_http) do
      result = @harvester.send(:http_get, "https://example.com/api?key=test")
      assert_equal "response_body", result
    end
  end

  # ── print_summary ──────────────────────────────────────────────

  test "print_summary logs results for each NIF" do
    @harvester.results["501412727"] = { "totalResults" => 5, "publications" => [{ "hasPeople" => true }] }
    @harvester.results["999999999"] = { "error" => "search_failed" }

    output = capture_io { @harvester.send(:print_summary) }.first
    assert_includes output, "501412727"
    assert_includes output, "5 results"
    assert_includes output, "1 with people"
    assert_includes output, "999999999"
    assert_includes output, "ERROR"
  end

  # ── detail popup handling ──────────────────────────────────────

  test "detail_link_selector matches the ASP.NET grid row link" do
    row = { "rowIndex" => 3 }

    assert_equal(
      "#ctl00_ContentPlaceHolderMain_gvSearchResult tr:nth-child(4) td:nth-child(6) a",
      @harvester.send(:detail_link_selector, row)
    )
  end

  test "fetch_publication_detail opens popup and extracts html and text" do
    popup_closed = false
    popup = Object.new
    popup.define_singleton_method(:current_url) { "https://publicacoes.mj.pt/DetalhePublicacao.aspx" }
    popup.define_singleton_method(:evaluate) do |_script|
      {
        "html" => "<b>Gerente:</b> Jane Doe",
        "text" => "Gerente: Jane Doe"
      }
    end
    popup.define_singleton_method(:close) { popup_closed = true }

    clickable = Object.new
    clickable.define_singleton_method(:click) { true }

  page = Object.new
  page.define_singleton_method(:at_css) { |_selector| clickable }
  page.define_singleton_method(:evaluate) { |_script| true }

  browser = Object.new
  browser.define_singleton_method(:windows) { [popup] }

    @harvester.instance_variable_set(:@browser, browser)
  @harvester.instance_variable_set(:@page, page)

    row = {
      "date" => "2024-02-08",
      "entity" => "SMITH & NEPHEW LDA",
      "acto" => "Designação de membro(s) de orgão(s) social(ais)",
      "concelho" => "Vila Franca de Xira",
      "conteudoHref" => "javascript:__doPostBack('ctl00$ContentPlaceHolderMain$gvSearchResult','Conteudo$1')",
      "rowIndex" => 1
    }

    @harvester.stub(:sleep, nil) do
      publication = @harvester.send(:fetch_publication_detail, row)

      assert_equal "2024-02-08", publication["date"]
      assert_equal "SMITH & NEPHEW LDA", publication["entity"]
      assert publication["hasPeople"]
      assert_includes publication["html"], "Gerente"
      assert popup_closed
    end
  end

  # ── on_nif_complete callback ─────────────────────────────────

  test "notify_nif_complete calls the callback with nif and data" do
    callback_calls = []
    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key",
      output_path: @output_path,
      on_nif_complete: ->(nif, data) { callback_calls << [nif, data] }
    )
    harvester.results["501412727"] = { "totalResults" => 5 }

    harvester.send(:notify_nif_complete, "501412727")

    assert_equal 1, callback_calls.size
    assert_equal "501412727", callback_calls[0][0]
    assert_equal({ "totalResults" => 5 }, callback_calls[0][1])
  end

  test "notify_nif_complete swallows callback errors" do
    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key",
      output_path: @output_path,
      on_nif_complete: ->(_nif, _data) { raise "boom" }
    )
    harvester.results["501412727"] = { "totalResults" => 5 }

    assert_nothing_raised { harvester.send(:notify_nif_complete, "501412727") }
  end

  test "harvest saves completed work before re-raising captcha balance errors" do
    browser = Object.new
    browser.define_singleton_method(:quit) { true }

    page = Object.new
    page.define_singleton_method(:go_to) { |_url| true }
    browser.define_singleton_method(:create_page) { page }

    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key",
      output_path: @output_path,
      headless: true
    )

    first_result = { "totalResults" => 3, "rows" => [], "publications" => [] }

    Object.const_set(:Ferrum, Module.new) unless defined?(Ferrum)
    ferrum_browser = Class.new do
      def initialize(browser)
        @browser = browser
      end

      def new(*_args, **_kwargs)
        @browser
      end
    end

    original_browser = Ferrum.const_get(:Browser) if Ferrum.const_defined?(:Browser, false)
    Ferrum.send(:remove_const, :Browser) if Ferrum.const_defined?(:Browser, false)
    Ferrum.const_set(:Browser, ferrum_browser.new(browser))

    harvester.stub(:sleep, nil) do
      harvester.stub(:skip?, false) do
        harvester.stub(:captcha_balance, "1.00") do
          harvester.stub(:harvest_nif, ->(nif) {
            if nif == "501412727"
              harvester.results[nif] = first_result
            else
              raise PublicContracts::PT::RegistoComercialHarvester::CaptchaBalanceError, "balance empty"
            end
          }) do
            error = assert_raises(PublicContracts::PT::RegistoComercialHarvester::CaptchaBalanceError) do
              harvester.harvest(%w[501412727 500043256])
            end

            assert_equal "balance empty", error.message
          end
        end
      end
    end

    saved = JSON.parse(File.read(@output_path))
    assert_equal 3, saved["501412727"]["totalResults"]
    refute saved.key?("500043256")
  ensure
    if defined?(original_browser) && original_browser
      Ferrum.send(:remove_const, :Browser) if Ferrum.const_defined?(:Browser, false)
      Ferrum.const_set(:Browser, original_browser)
    end
    if defined?(Ferrum) && Ferrum.is_a?(Module) && Ferrum.name.nil?
      Object.send(:remove_const, :Ferrum)
    end
  end

  test "harvest records per-nif errors and continues" do
    browser = Object.new
    browser.define_singleton_method(:quit) { true }

    page = Object.new
    page.define_singleton_method(:go_to) { |_url| true }
    browser.define_singleton_method(:create_page) { page }

    harvester = PublicContracts::PT::RegistoComercialHarvester.new(
      captcha_key: "test_key",
      output_path: @output_path,
      headless: true
    )

    Object.const_set(:Ferrum, Module.new) unless defined?(Ferrum)
    ferrum_browser = Class.new do
      def initialize(browser)
        @browser = browser
      end

      def new(*_args, **_kwargs)
        @browser
      end
    end

    original_browser = Ferrum.const_get(:Browser) if Ferrum.const_defined?(:Browser, false)
    Ferrum.send(:remove_const, :Browser) if Ferrum.const_defined?(:Browser, false)
    Ferrum.const_set(:Browser, ferrum_browser.new(browser))

    harvester.stub(:sleep, nil) do
      harvester.stub(:skip?, false) do
        harvester.stub(:captcha_balance, "1.00") do
          harvester.stub(:harvest_nif, ->(nif) {
            raise "timeout" if nif == "501412727"

            harvester.results[nif] = { "totalResults" => 1, "rows" => [], "publications" => [] }
          }) do
            assert_nothing_raised do
              harvester.harvest(%w[501412727 500043256])
            end
          end
        end
      end
    end

    saved = JSON.parse(File.read(@output_path))
    assert_equal "timeout", saved["501412727"]["error"]
    assert_equal 1, saved["500043256"]["totalResults"]
  ensure
    if defined?(original_browser) && original_browser
      Ferrum.send(:remove_const, :Browser) if Ferrum.const_defined?(:Browser, false)
      Ferrum.const_set(:Browser, original_browser)
    end
    if defined?(Ferrum) && Ferrum.is_a?(Module) && Ferrum.name.nil?
      Object.send(:remove_const, :Ferrum)
    end
  end

  test "notify_nif_complete is a no-op when callback is nil" do
    assert_nothing_raised { @harvester.send(:notify_nif_complete, "501412727") }
  end

  test "do_search retries when NIF input field is missing" do
    search_clicked = false
    go_to_calls = 0

    search_button = Object.new
    search_button.define_singleton_method(:click) { search_clicked = true }

    page = Object.new
    page.define_singleton_method(:at_css) do |selector|
      case selector
      when PublicContracts::PT::RegistoComercialHarvester::SEARCH_BTN_SEL
        search_button
      when PublicContracts::PT::RegistoComercialHarvester::GRID_SEL
        Object.new
      else
        nil
      end
    end
    page.define_singleton_method(:go_to) { |_url| go_to_calls += 1 }

    @harvester.instance_variable_set(:@page, page)

    attempts = 0
    @harvester.stub(:set_nif_input!, ->(_nif) { attempts += 1; attempts > 1 }) do
      @harvester.stub(:solve_nobot, nil) do
        @harvester.stub(:solve_captcha, "token_123") do
          @harvester.stub(:inject_captcha_token, nil) do
            @harvester.stub(:wait_for_load, nil) do
              @harvester.stub(:sleep, nil) do
                result = @harvester.send(:do_search, "501412727")
                assert_equal :success, result
              end
            end
          end
        end
      end
    end

    assert_equal 1, go_to_calls
    assert search_clicked
  end

  # ── harvest integration (mocked browser) ───────────────────────

  test "harvest skips already-harvested NIFs and quits browser" do
    @harvester.results["501412727"] = { "totalResults" => 5, "rows" => [], "publications" => [] }

    browser_quit_called = false
    fake_page = Object.new
    fake_page.define_singleton_method(:go_to) { |_url| }
    fake_browser = Object.new
    fake_browser.define_singleton_method(:create_page) { fake_page }
    fake_browser.define_singleton_method(:quit) { browser_quit_called = true }
    fake_browser.define_singleton_method(:network) {
      net = Object.new
      net.define_singleton_method(:wait_for_idle) { |**_| }
      net
    }

    Ferrum::Browser.stub(:new, ->(**_opts) { fake_browser }) do
      @harvester.stub(:sleep, nil) do
        @harvester.stub(:captcha_balance, "5.00") do
          @harvester.harvest(["501412727"])
        end
      end
    end

    assert browser_quit_called
    # NIF was skipped, results unchanged
    assert_equal 5, @harvester.results["501412727"]["totalResults"]
  end
end
