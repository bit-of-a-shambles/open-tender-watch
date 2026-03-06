require "test_helper"

class PublicContracts::EU::TedClientTest < ActiveSupport::TestCase
  FULL_NOTICE = {
    "publication-number"         => "2026/S001-001",
    "procedure-identifier"       => "proc-uuid-001",
    "publication-date"           => "2026-01-15Z",
    "notice-type"                => "cn-standard",
    "notice-title"               => { "eng" => "Supply of surgical equipment", "por" => "Fornecimento de equipamento cirúrgico" },
    "organisation-country-buyer" => [ "PRT" ],
    "organisation-name-buyer"    => { "eng" => [ "Centro Hospitalar Lisboa Norte" ] },
    "BT-105-Procedure"           => "open",
    "BT-27-Procedure"            => "732000",
    "BT-27-Procedure-Currency"   => "EUR",
    "main-classification-proc"   => [ "50100000" ],
    "BT-5071-Procedure"          => [ "PT300" ]
  }.freeze

  NOTICES_PAYLOAD = {
    "notices"          => [ FULL_NOTICE ],
    "totalNoticeCount" => 32000
  }.freeze

  def fake_success(body)
    resp = Net::HTTPSuccess.new("1.1", "200", "OK")
    resp.instance_variable_set(:@body, body)
    resp.define_singleton_method(:body) { body }
    resp
  end

  def fake_error(code = "500", message = "Server Error", headers = {})
    resp = Object.new
    resp.define_singleton_method(:is_a?) { |_klass| false }
    resp.define_singleton_method(:body)  { "" }
    resp.define_singleton_method(:code)  { code }
    resp.define_singleton_method(:message) { message }
    resp.define_singleton_method(:[]) { |key| headers[key] }
    resp
  end

  def mock_http_post(response)
    mock = Minitest::Mock.new
    mock.expect(:use_ssl=,      nil, [ TrueClass ])
    mock.expect(:open_timeout=, nil, [ Integer ])
    mock.expect(:read_timeout=, nil, [ Integer ])
    mock.expect(:request,       response, [ Net::HTTP::Post ])
    mock
  end

  setup do
    @client = PublicContracts::EU::TedClient.new
  end

  test "source_name" do
    assert_equal "TED — Tenders Electronic Daily", @client.source_name
  end

  test "country_code is EU" do
    assert_equal "EU", @client.country_code
  end

  test "search returns parsed response on success" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.search(query: "organisation-country-buyer=PRT")
      assert_equal NOTICES_PAYLOAD, result
    end
    mock.verify
  end

  test "search returns nil on HTTP error" do
    mock = mock_http_post(fake_error("500", "Server Error"))
    Net::HTTP.stub(:new, mock) do
      result = @client.search(query: "organisation-country-buyer=PRT")
      assert_nil result
    end
    mock.verify
  end

  test "search returns nil on network exception" do
    raising_mock = Object.new
    raising_mock.define_singleton_method(:use_ssl=)      { |_| }
    raising_mock.define_singleton_method(:open_timeout=) { |_| }
    raising_mock.define_singleton_method(:read_timeout=) { |_| }
    raising_mock.define_singleton_method(:request)       { |_| raise Errno::ECONNREFUSED }
    Net::HTTP.stub(:new, raising_mock) do
      result = @client.search(query: "test")
      assert_nil result
    end
  end

  test "portuguese_contracts calls search with PRT" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.portuguese_contracts(limit: 5)
      assert_equal NOTICES_PAYLOAD, result
    end
    mock.verify
  end

  test "notices_for_country without keyword" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.notices_for_country("ESP")
      assert_equal NOTICES_PAYLOAD, result
    end
    mock.verify
  end

  test "notices_for_country with keyword" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.notices_for_country("PRT", keyword: "construction")
      assert_equal NOTICES_PAYLOAD, result
    end
    mock.verify
  end

  test "fetch_contracts returns normalized contracts array" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal 1, result.size
      assert_equal "proc-uuid-001", result.first["external_id"]
    end
    mock.verify
  end

  test "total_count returns totalNoticeCount from search response" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      assert_equal 32000, @client.total_count
    end
    mock.verify
  end

  test "total_count returns 0 when search fails" do
    mock = mock_http_post(fake_error)
    Net::HTTP.stub(:new, mock) do
      assert_equal 0, @client.total_count
    end
    mock.verify
  end

  test "fetch_contracts returns empty array when search fails" do
    mock = mock_http_post(fake_error)
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal [], result
    end
    mock.verify
  end

  test "accepts api_key from config" do
    client = PublicContracts::EU::TedClient.new("api_key" => "test-key")
    assert_instance_of PublicContracts::EU::TedClient, client
  end

  test "fetch_contracts uses configured country_code" do
    client = PublicContracts::EU::TedClient.new("country_code" => "ESP")
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = client.fetch_contracts
      assert_equal 1, result.size
      assert_equal "proc-uuid-001", result.first["external_id"]
    end
    mock.verify
  end

  test "normalize uses procedure-identifier as external_id" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "proc-uuid-001", result.first["external_id"]
    end
    mock.verify
  end

  test "normalize falls back to publication-number when procedure-identifier absent" do
    notice_no_proc_id = FULL_NOTICE.except("procedure-identifier")
    payload = { "notices" => [ notice_no_proc_id ], "totalNoticeCount" => 1 }
    mock = mock_http_post(fake_success(payload.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "2026/S001-001", result.first["external_id"]
    end
    mock.verify
  end

  test "normalize strips Z suffix from publication-date" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "2026-01-15", result.first["publication_date"]
    end
    mock.verify
  end

  test "normalize prefers English notice title" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "Supply of surgical equipment", result.first["object"]
    end
    mock.verify
  end

  test "normalize falls back to Portuguese title when no English" do
    notice = FULL_NOTICE.merge("notice-title" => { "por" => "Fornecimento de equipamento" })
    payload = { "notices" => [ notice ], "totalNoticeCount" => 1 }
    mock = mock_http_post(fake_success(payload.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "Fornecimento de equipamento", result.first["object"]
    end
    mock.verify
  end

  test "normalize sets country_code PT for PRT buyer country" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "PT", result.first["country_code"]
    end
    mock.verify
  end

  test "normalize builds contracting_entity with synthetic id and buyer name" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      entity = result.first["contracting_entity"]
      assert entity["tax_identifier"].start_with?("TED-")
      assert_equal "Centro Hospitalar Lisboa Norte", entity["name"]
      assert entity["is_public_body"]
    end
    mock.verify
  end

  test "normalize synthetic id is deterministic for same buyer name" do
    mock1 = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    mock2 = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    id1 = Net::HTTP.stub(:new, mock1) { @client.fetch_contracts.first.dig("contracting_entity", "tax_identifier") }
    id2 = Net::HTTP.stub(:new, mock2) { @client.fetch_contracts.first.dig("contracting_entity", "tax_identifier") }
    assert_equal id1, id2
  end

  test "normalize maps procedure type" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "open", result.first["procedure_type"]
    end
    mock.verify
  end

  test "normalize maps base_price as BigDecimal" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal BigDecimal("732000"), result.first["base_price"]
    end
    mock.verify
  end

  test "normalize maps CPV code from main-classification-proc" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "50100000", result.first["cpv_code"]
    end
    mock.verify
  end

  test "normalize maps location from BT-5071-Procedure" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "PT300", result.first["location"]
    end
    mock.verify
  end

  test "normalize handles missing optional fields gracefully" do
    notice = { "publication-number" => "X-001", "organisation-country-buyer" => [ "PRT" ],
               "organisation-name-buyer" => { "eng" => [ "Test Org" ] } }
    payload = { "notices" => [ notice ], "totalNoticeCount" => 1 }
    mock = mock_http_post(fake_success(payload.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_nil result.first["base_price"]
      assert_nil result.first["cpv_code"]
      assert_nil result.first["location"]
      assert_nil result.first["procedure_type"]
    end
    mock.verify
  end

  test "normalize sets empty winners array" do
    mock = mock_http_post(fake_success(NOTICES_PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal [], result.first["winners"]
    end
    mock.verify
  end

  test "normalize returns nil for corrigendum notice type" do
    mock = mock_http_post(fake_success({ "notices" => [ FULL_NOTICE.merge("notice-type" => "cor") ], "totalNoticeCount" => 1 }.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal [], result
    end
    mock.verify
  end

  test "normalize returns nil for can-modifies notice type" do
    mock = mock_http_post(fake_success({ "notices" => [ FULL_NOTICE.merge("notice-type" => "can-modifies") ], "totalNoticeCount" => 1 }.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal [], result
    end
    mock.verify
  end

  test "fetch_contracts compacts skipped notice types" do
    cn_notice  = FULL_NOTICE
    cor_notice = FULL_NOTICE.merge("notice-type" => "cor", "publication-number" => "2026/S001-002")
    payload    = { "notices" => [ cn_notice, cor_notice ], "totalNoticeCount" => 2 }.to_json
    mock = mock_http_post(fake_success(payload))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal 1, result.length
      assert_equal "proc-uuid-001", result.first["external_id"]
    end
    mock.verify
  end

  test "extract_title strips leading country segment from TED title" do
    title_with_country = { "eng" => "Portugal \u2013 Computer support services \u2013 Actual contract title" }
    assert_equal "Computer support services \u2013 Actual contract title", @client.send(:extract_title, title_with_country)
  end

  test "extract_title returns title unchanged when no en-dash separator" do
    titles = { "eng" => "Supply of surgical equipment" }
    assert_equal "Supply of surgical equipment", @client.send(:extract_title, titles)
  end

  test "extract_title returns nil for non-hash input" do
    assert_nil @client.send(:extract_title, nil)
    assert_nil @client.send(:extract_title, "plain string")
  end

  test "extract_title returns first value when no EN or PT" do
    titles = { "fra" => "Fournitures médicales", "deu" => "Medizinische Versorgung" }
    assert_equal "Fournitures médicales", @client.send(:extract_title, titles)
  end

  test "extract_buyer_name extracts from eng array" do
    field = { "eng" => [ "European Maritime Safety Agency" ] }
    assert_equal "European Maritime Safety Agency", @client.send(:extract_buyer_name, field)
  end

  test "extract_buyer_name falls back to first language" do
    field = { "por" => [ "Câmara Municipal de Lisboa" ] }
    assert_equal "Câmara Municipal de Lisboa", @client.send(:extract_buyer_name, field)
  end

  test "extract_buyer_name returns Unknown for nil" do
    assert_equal "Unknown", @client.send(:extract_buyer_name, nil)
  end

  test "inter_page_delay returns the configured default" do
    assert_equal PublicContracts::EU::TedClient::DEFAULT_INTER_PAGE_DELAY, @client.inter_page_delay
  end

  test "search retries on 429 and returns result after wait" do
    call_count   = 0
    success_resp = fake_success(NOTICES_PAYLOAD.to_json)
    rate_limited = fake_error("429", "Too Many Requests", { "Retry-After" => "0" })

    stateful = Object.new
    stateful.define_singleton_method(:use_ssl=)      { |_| }
    stateful.define_singleton_method(:open_timeout=) { |_| }
    stateful.define_singleton_method(:read_timeout=) { |_| }
    stateful.define_singleton_method(:request) do |_req|
      call_count += 1
      call_count == 1 ? rate_limited : success_resp
    end

    Net::HTTP.stub(:new, stateful) do
      result = @client.search(query: "test")
      assert_equal NOTICES_PAYLOAD, result
    end
    assert_equal 2, call_count
  end

  test "rails_log falls back to warn when Rails logger is nil" do
    original_logger = Rails.logger
    Rails.logger = nil
    warning_issued = false
    raising_mock = Object.new
    raising_mock.define_singleton_method(:use_ssl=)      { |_| }
    raising_mock.define_singleton_method(:open_timeout=) { |_| }
    raising_mock.define_singleton_method(:read_timeout=) { |_| }
    raising_mock.define_singleton_method(:request)       { |_| raise StandardError, "no logger test" }
    @client.stub(:warn, ->(_msg) { warning_issued = true }) do
      Net::HTTP.stub(:new, raising_mock) do
        result = @client.search(query: "test")
        assert_nil result
      end
    end
    assert warning_issued, "expected warn to be called when Rails.logger is nil"
  ensure
    Rails.logger = original_logger
  end
end
