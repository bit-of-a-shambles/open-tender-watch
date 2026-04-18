require "test_helper"

class PublicContracts::PT::QuemFaturaClientTest < ActiveSupport::TestCase
  RECORD = {
    "idcontrato"          => "11136902",
    "objectoContrato"     => "Aquisição de equipamentos de áudio - OA028424",
    "precoContratual"     => 28814.0,
    "dataPublicacao"      => "2025-01-07",
    "adjudicante"         => [ "500792771" ],
    "adjudicatarios"      => [ "502303298" ],
    "adjudicante_ids"     => [ 86852 ],
    "adjudicatario_ids"   => [ 97965 ],
    "adjudicante_nomes"   => [ "Banco de Portugal" ],
    "adjudicatario_nomes" => [ "Pantalha - Sistemas de Processamento de Imagem, Lda" ],
    "tipoprocedimento"    => "Consulta Prévia"
  }.freeze

  PAYLOAD = {
    "total_count" => 23503,
    "skip"        => 0,
    "limit"       => 1,
    "contracts"   => [ RECORD ]
  }.freeze

  def fake_success(body)
    resp = Net::HTTPSuccess.new("1.1", "200", "OK")
    resp.instance_variable_set(:@body, body)
    resp.define_singleton_method(:body) { body }
    resp
  end

  def fake_error(code = "500", message = "Error")
    resp = Object.new
    resp.define_singleton_method(:is_a?) { |_| false }
    resp.define_singleton_method(:code)    { code }
    resp.define_singleton_method(:message) { message }
    resp
  end

  def mock_http(response)
    mock = Minitest::Mock.new
    mock.expect(:use_ssl=,      nil, [ TrueClass ])
    mock.expect(:open_timeout=, nil, [ Integer ])
    mock.expect(:read_timeout=, nil, [ Integer ])
    mock.expect(:request,       response, [ Net::HTTP::Get ])
    mock
  end

  def fake_http_with_responses(*responses)
    http = Object.new
    http.instance_variable_set(:@responses, responses)
    http.define_singleton_method(:use_ssl=) { |_| nil }
    http.define_singleton_method(:open_timeout=) { |_| nil }
    http.define_singleton_method(:read_timeout=) { |_| nil }
    http.define_singleton_method(:request) do |_request|
      raise "No queued HTTP responses left" if @responses.empty?

      @responses.shift
    end
    http
  end

  setup do
    @client = PublicContracts::PT::QuemFaturaClient.new("fetch_details" => false)
  end

  test "country_code is PT" do
    assert_equal "PT", @client.country_code
  end

  test "source_name" do
    assert_equal "QuemFatura.pt", @client.source_name
  end

  test "fetch_contracts returns array on success" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal 1, result.size
    end
    mock.verify
  end

  test "fetch_contracts returns empty array on HTTP error" do
    mock = mock_http(fake_error)
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal [], result
    end
    mock.verify
  end

  test "fetch_contracts returns empty array on exception" do
    raising = Object.new
    raising.define_singleton_method(:use_ssl=)      { |_| }
    raising.define_singleton_method(:open_timeout=) { |_| }
    raising.define_singleton_method(:read_timeout=) { |_| }
    raising.define_singleton_method(:request)       { |_| raise Errno::ECONNREFUSED }
    Net::HTTP.stub(:new, raising) do
      result = @client.fetch_contracts
      assert_equal [], result
    end
  end

  test "total_count returns total_count from response" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      assert_equal 23503, @client.total_count
    end
    mock.verify
  end

  test "total_count returns 0 when request fails" do
    mock = mock_http(fake_error)
    Net::HTTP.stub(:new, mock) do
      assert_equal 0, @client.total_count
    end
    mock.verify
  end

  test "normalize maps idcontrato to external_id" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "11136902", result.first["external_id"]
    end
    mock.verify
  end

  test "normalize maps objectoContrato to object" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "Aquisição de equipamentos de áudio - OA028424", result.first["object"]
    end
    mock.verify
  end

  test "normalize sets country_code to PT" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "PT", result.first["country_code"]
    end
    mock.verify
  end

  test "normalize maps tipoprocedimento to procedure_type" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal "Consulta Prévia", result.first["procedure_type"]
    end
    mock.verify
  end

  test "normalize maps dataPublicacao as Date" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal Date.new(2025, 1, 7), result.first["publication_date"]
    end
    mock.verify
  end

  test "normalize maps precoContratual as BigDecimal" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contracts
      assert_equal BigDecimal("28814.0"), result.first["base_price"]
    end
    mock.verify
  end

  test "normalize builds contracting_entity with NIF and name" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result    = @client.fetch_contracts
      authority = result.first["contracting_entity"]
      assert_equal "500792771",      authority["tax_identifier"]
      assert_equal "Banco de Portugal", authority["name"]
      assert authority["is_public_body"]
    end
    mock.verify
  end

  test "normalize builds winners array" do
    mock = mock_http(fake_success(PAYLOAD.to_json))
    Net::HTTP.stub(:new, mock) do
      result  = @client.fetch_contracts
      winners = result.first["winners"]
      assert_equal 1, winners.size
      assert_equal "502303298", winners.first["tax_identifier"]
      assert_equal "Pantalha - Sistemas de Processamento de Imagem, Lda", winners.first["name"]
      assert winners.first["is_company"]
    end
    mock.verify
  end

  test "normalize handles multiple winners" do
    multi = RECORD.merge(
      "adjudicatarios"      => [ "111111111", "222222222" ],
      "adjudicatario_nomes" => [ "Empresa Alpha", "Empresa Beta" ]
    )
    payload = PAYLOAD.merge("contracts" => [ multi ])
    mock = mock_http(fake_success(payload.to_json))
    Net::HTTP.stub(:new, mock) do
      result  = @client.fetch_contracts
      winners = result.first["winners"]
      assert_equal 2, winners.size
      assert_equal "111111111", winners.first["tax_identifier"]
      assert_equal "222222222", winners.last["tax_identifier"]
    end
    mock.verify
  end

  test "accepts cf_clearance from config" do
    client = PublicContracts::PT::QuemFaturaClient.new("cf_clearance" => "test-token")
    assert_instance_of PublicContracts::PT::QuemFaturaClient, client
  end

  test "fetch_details defaults to true for richer imports" do
    client = PublicContracts::PT::QuemFaturaClient.new
    assert client.instance_variable_get(:@fetch_details)
  end

  test "accepts page_size from config" do
    client = PublicContracts::PT::QuemFaturaClient.new("page_size" => "50")
    assert_instance_of PublicContracts::PT::QuemFaturaClient, client
  end

  test "parse_date returns nil for blank" do
    assert_nil @client.send(:parse_date, nil)
    assert_nil @client.send(:parse_date, "")
  end

  test "parse_date returns nil for invalid date" do
    assert_nil @client.send(:parse_date, "not-a-date")
  end

  test "parse_decimal returns nil for nil" do
    assert_nil @client.send(:parse_decimal, nil)
  end

  test "parse_decimal returns nil for non-numeric string" do
    assert_nil @client.send(:parse_decimal, "not-a-number")
  end

  test "rails_log falls back to warn when Rails.logger is nil" do
    original = Rails.logger
    Rails.logger = nil
    _out, err = capture_io { @client.send(:rails_log, "fallback test") }
    assert_includes err, "fallback test"
  ensure
    Rails.logger = original
  end

  test "extract_cpv returns the numeric code portion of a CPV string" do
    assert_equal "33000000", @client.send(:extract_cpv, "33000000-0 - Equipamentos médicos")
  end

  test "fetch_contract_detail returns summary unchanged when idcontrato is missing" do
    summary = { "objectoContrato" => "Test", "precoContratual" => 100.0 }
    assert_equal summary, @client.fetch_contract_detail(summary)
  end

  test "fetch_contract_detail merges detail fields into the summary" do
    summary = { "idcontrato" => "12345", "objectoContrato" => "Test" }
    detail  = { "idcontrato" => "12345", "localExecucao" => "Lisboa", "dataCelebracaoContrato" => "2025-01-01" }
    mock = mock_http(fake_success(detail.to_json))
    Net::HTTP.stub(:new, mock) do
      result = @client.fetch_contract_detail(summary)
      assert_equal "Lisboa", result["localExecucao"]
      assert_equal "Test",   result["objectoContrato"]
    end
    mock.verify
  end

  test "normalize maps contract_type and total_effective_price from detail-like fields" do
    contract = RECORD.merge(
      "tipoContrato" => "Aquisição de Serviços",
      "precoTotalEfetivo" => "27700.55"
    )
    normalized = @client.send(:normalize, contract)
    assert_equal "Aquisição de Serviços", normalized["contract_type"]
    assert_equal BigDecimal("27700.55"), normalized["total_effective_price"]
  end

  test "fetch_contracts with details maps celebration_date contract_type cpv and location" do
    client = PublicContracts::PT::QuemFaturaClient.new("fetch_details" => true)
    detail_payload = {
      "contract" => {
        "dataCelebracaoContrato" => "2025-01-10",
        "tipoContrato" => "Aquisição de Serviços",
        "cpvs" => [ "33000000-0 - Equipamentos médicos" ],
        "localExecucao" => "Lisboa"
      }
    }
    http = fake_http_with_responses(
      fake_success(PAYLOAD.to_json),
      fake_success(detail_payload.to_json)
    )

    Net::HTTP.stub(:new, http) do
      contract = client.fetch_contracts.first
      assert_equal Date.new(2025, 1, 10), contract["celebration_date"]
      assert_equal "Aquisição de Serviços", contract["contract_type"]
      assert_equal "33000000", contract["cpv_code"]
      assert_equal "Lisboa", contract["location"]
    end
  end

  test "normalize extracts detail fields from alternate structures" do
    contract = RECORD.merge(
      "dataCelebracao" => "2025-02-14",
      "tipocontrato" => { "descricao" => "Empreitada de obras públicas" },
      "cpvs" => [ { "codigo" => "45000000-7" } ],
      "localExecucao" => { "descricao" => "Porto" }
    )

    normalized = @client.send(:normalize, contract)
    assert_equal Date.new(2025, 2, 14), normalized["celebration_date"]
    assert_equal "Empreitada de obras públicas", normalized["contract_type"]
    assert_equal "45000000", normalized["cpv_code"]
    assert_equal "Porto", normalized["location"]
  end

  test "extract_text returns first present value from arrays" do
    value = [ "", { "descricao" => "Setúbal" } ]
    assert_equal "Setúbal", @client.send(:extract_text, value)
  end

  test "extract_cpv returns nil when array has no usable value" do
    assert_nil @client.send(:extract_cpv, [ "", nil, { "descricao" => "sem cpv" } ])
  end

  test "extract_text returns nil when array has no present value" do
    assert_nil @client.send(:extract_text, [ "", nil, { "foo" => "bar" } ])
  end
end
