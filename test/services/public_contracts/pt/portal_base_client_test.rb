require "test_helper"

class PublicContracts::PT::PortalBaseClientTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  SAMPLE_RESOURCES = [
    { "title" => "contratos2024.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2024.xlsx" },
    { "title" => "contratos2025.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2025.xlsx" },
    { "title" => "contratos2025.csv",  "format" => "csv",  "url" => "https://example.com/contratos2025.csv" }
  ].freeze

  SAMPLE_DATASET_RESPONSE = { "resources" => SAMPLE_RESOURCES }.freeze

  SAMPLE_ROW = {
    "idcontrato"             => "12345",
    "objectoContrato"        => "Prestação de serviços de limpeza",
    "tipoprocedimento"       => "Ajuste Direto",
    "tipoContrato"           => "Prestação de Serviços",
    "adjudicante"            => "504595067 - Câmara Municipal de Lisboa",
    "adjudicatarios"         => "123456789 - Empresa ABC, Lda",
    "dataPublicacao"         => Date.new(2024, 3, 15),
    "dataCelebracaoContrato" => Date.new(2024, 3, 10),
    "precoBaseProcedimento"  => 5000.0,
    "precoContratual"        => 4800.0,
    "PrecoTotalEfetivo"      => 4900.0,
    "CPV"                    => "90910000-9 - Serviços de limpeza",
    "LocalExecucao"          => "PT170",
    "Ano"                    => 2024
  }.freeze

  def fake_http_success(body_hash)
    resp = Object.new
    resp.define_singleton_method(:is_a?) { |klass| klass == Net::HTTPSuccess || klass == NilClass ? false : klass <= Net::HTTPSuccess }
    resp.define_singleton_method(:body)  { body_hash.to_json }
    # Override is_a? to return true for Net::HTTPSuccess
    resp.define_singleton_method(:is_a?) { |klass| klass <= Net::HTTPSuccess rescue false }
    resp
  end

  def fake_http_error(code = "500")
    resp = Object.new
    resp.define_singleton_method(:is_a?) { |_klass| false }
    resp.define_singleton_method(:code)  { code }
    resp.define_singleton_method(:message) { "Error" }
    resp
  end

  # Build a minimal Roo::Spreadsheet mock
  def mock_roo_sheet(rows)
    # rows is an array of arrays; first row is headers
    sheet_mock = Minitest::Mock.new
    sheet_mock.expect(:row, rows[0], [ 1 ])
    sheet_mock.expect(:last_row, rows.size)
    (2..rows.size).each_with_index do |row_num, idx|
      sheet_mock.expect(:row, rows[idx + 1 - 1 + 1 - 1], [ row_num ])
    end
    sheet_mock
  end

  setup do
    @client = PublicContracts::PT::PortalBaseClient.new("years" => [ 2024 ])
  end

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  test "country_code is PT" do
    assert_equal "PT", @client.country_code
  end

  test "source_name is Portal BASE" do
    assert_equal "Portal BASE", @client.source_name
  end

  # ---------------------------------------------------------------------------
  # parse_entity
  # ---------------------------------------------------------------------------

  test "parse_entity parses NIF and name" do
    result = @client.send(:parse_entity, "504595067 - Câmara Municipal de Lisboa")
    assert_equal "504595067", result["tax_identifier"]
    assert_equal "Câmara Municipal de Lisboa", result["name"]
    assert result["is_public_body"]
  end

  test "parse_entity handles em-dash separator" do
    result = @client.send(:parse_entity, "504595067 – Câmara Municipal")
    assert_equal "504595067", result["tax_identifier"]
  end

  test "parse_entity returns nil for blank input" do
    assert_nil @client.send(:parse_entity, nil)
    assert_nil @client.send(:parse_entity, "")
  end

  test "parse_entity returns nil when no NIF present" do
    assert_nil @client.send(:parse_entity, "Just a name without NIF")
  end

  # ---------------------------------------------------------------------------
  # parse_winners
  # ---------------------------------------------------------------------------

  test "parse_winners parses single winner" do
    result = @client.send(:parse_winners, "123456789 - Empresa ABC, Lda")
    assert_equal 1, result.size
    assert_equal "123456789", result[0]["tax_identifier"]
    assert_equal "Empresa ABC, Lda", result[0]["name"]
    assert result[0]["is_company"]
  end

  test "parse_winners parses multiple winners on separate lines" do
    raw = "111111111 - Empresa Alpha\n222222222 - Empresa Beta, SA"
    result = @client.send(:parse_winners, raw)
    assert_equal 2, result.size
    assert_equal "111111111", result[0]["tax_identifier"]
    assert_equal "222222222", result[1]["tax_identifier"]
  end

  test "parse_winners strips leading position counter from name" do
    raw = "123456789 - 1 - Empresa Com Posição"
    result = @client.send(:parse_winners, raw)
    assert_equal "Empresa Com Posição", result[0]["name"]
  end

  test "parse_winners returns empty array for blank input" do
    assert_equal [], @client.send(:parse_winners, nil)
    assert_equal [], @client.send(:parse_winners, "")
  end

  # ---------------------------------------------------------------------------
  # parse_cpv
  # ---------------------------------------------------------------------------

  test "parse_cpv extracts 8-digit code" do
    assert_equal "90910000", @client.send(:parse_cpv, "90910000-9 - Serviços de limpeza")
  end

  test "parse_cpv returns nil for blank" do
    assert_nil @client.send(:parse_cpv, nil)
    assert_nil @client.send(:parse_cpv, "")
  end

  # ---------------------------------------------------------------------------
  # parse_date
  # ---------------------------------------------------------------------------

  test "parse_date handles Date objects" do
    d = Date.new(2024, 3, 15)
    assert_equal d, @client.send(:parse_date, d)
  end

  test "parse_date handles date strings" do
    assert_equal Date.new(2024, 3, 15), @client.send(:parse_date, "2024-03-15")
  end

  test "parse_date returns nil for blank" do
    assert_nil @client.send(:parse_date, nil)
    assert_nil @client.send(:parse_date, "")
  end

  test "parse_date returns nil for invalid date" do
    assert_nil @client.send(:parse_date, "not-a-date")
  end

  # ---------------------------------------------------------------------------
  # parse_decimal
  # ---------------------------------------------------------------------------

  test "parse_decimal handles float" do
    result = @client.send(:parse_decimal, 4900.0)
    assert_instance_of BigDecimal, result
    assert_equal BigDecimal("4900"), result
  end

  test "parse_decimal handles string" do
    result = @client.send(:parse_decimal, "1234.56")
    assert_equal BigDecimal("1234.56"), result
  end

  test "parse_decimal returns nil for nil" do
    assert_nil @client.send(:parse_decimal, nil)
  end

  test "parse_decimal returns nil for invalid string" do
    assert_nil @client.send(:parse_decimal, "not-a-number")
  end

  # ---------------------------------------------------------------------------
  # normalize_row
  # ---------------------------------------------------------------------------

  test "normalize_row builds correct contract hash" do
    headers = SAMPLE_ROW.keys
    values  = SAMPLE_ROW.values
    result  = @client.send(:normalize_row, headers, values)

    assert_equal "12345",       result["external_id"]
    assert_equal "PT",          result["country_code"]
    assert_equal "Ajuste Direto", result["procedure_type"]
    assert_equal "504595067",   result["contracting_entity"]["tax_identifier"]
    assert_equal 1,             result["winners"].size
    assert_equal "90910000",    result["cpv_code"]
  end

  test "normalize_row returns nil when contracting entity NIF is missing" do
    headers = SAMPLE_ROW.keys
    values  = SAMPLE_ROW.values.dup.tap { |v| v[SAMPLE_ROW.keys.index("adjudicante")] = "No NIF here" }
    assert_nil @client.send(:normalize_row, headers, values)
  end

  test "normalize_row falls back to contractual price when effective is zero" do
    row = SAMPLE_ROW.merge("PrecoTotalEfetivo" => 0.0, "precoContratual" => 4800.0)
    result = @client.send(:normalize_row, row.keys, row.values)
    assert_equal BigDecimal("4800"), result["total_effective_price"]
  end

  # ---------------------------------------------------------------------------
  # fetch_resources
  # ---------------------------------------------------------------------------

  test "fetch_resources returns only xlsx resources" do
    Net::HTTP.stub(:get_response, fake_http_success(SAMPLE_DATASET_RESPONSE)) do
      resources = @client.send(:fetch_resources)
      assert_equal 2, resources.size
      resources.each { |r| assert_equal "xlsx", r["format"].downcase }
    end
  end

  test "fetch_resources returns empty array when API fails" do
    Net::HTTP.stub(:get_response, fake_http_error) do
      assert_equal [], @client.send(:fetch_resources)
    end
  end

  # ---------------------------------------------------------------------------
  # resource_year
  # ---------------------------------------------------------------------------

  test "resource_year extracts year from title" do
    res = { "title" => "contratos2025.xlsx" }
    assert_equal 2025, @client.send(:resource_year, res)
  end

  test "resource_year returns nil for unrecognised title" do
    assert_nil @client.send(:resource_year, { "title" => "readme.txt" })
  end

  # ---------------------------------------------------------------------------
  # fetch_contracts (streaming via stubbed stream_xlsx_resource)
  # ---------------------------------------------------------------------------

  test "fetch_contracts returns first page of matching rows" do
    resources = [ { "title" => "contratos2024.xlsx", "format" => "xlsx",
                    "url" => "https://example.com/contratos2024.xlsx" } ]
    rows = (1..10).map { |i| { "external_id" => i.to_s } }

    @client.stub(:fetch_resources, resources) do
      @client.stub(:stream_xlsx_resource, ->(url, &blk) { rows.each { |r| blk.call(r) } }) do
        result = @client.fetch_contracts(page: 1, limit: 4)
        assert_equal 4, result.size
        assert_equal "1", result.first["external_id"]
      end
    end
  end

  test "fetch_contracts paginates correctly" do
    resources = [ { "title" => "contratos2024.xlsx", "format" => "xlsx",
                    "url" => "https://example.com/contratos2024.xlsx" } ]
    rows = (1..10).map { |i| { "external_id" => i.to_s } }

    @client.stub(:fetch_resources, resources) do
      @client.stub(:stream_xlsx_resource, ->(url, &blk) { rows.each { |r| blk.call(r) } }) do
        page2 = @client.fetch_contracts(page: 2, limit: 4)
        assert_equal 4, page2.size
        assert_equal "5", page2.first["external_id"]
      end
    end
  end

  test "fetch_contracts returns empty array when no matching resource" do
    @client.stub(:fetch_resources, []) do
      assert_equal [], @client.fetch_contracts
    end
  end

  # ---------------------------------------------------------------------------
  # total_count
  # ---------------------------------------------------------------------------

  test "total_count sums rows across configured years" do
    resources = [ { "title" => "contratos2024.xlsx", "format" => "xlsx",
                    "url" => "https://example.com/contratos2024.xlsx" } ]
    @client.stub(:fetch_resources, resources) do
      @client.stub(:count_rows_in_resource, 42) do
        assert_equal 42, @client.total_count
      end
    end
  end

  test "total_count returns 0 when year not found" do
    @client.stub(:fetch_resources, []) do
      assert_equal 0, @client.total_count
    end
  end

  # ---------------------------------------------------------------------------
  # download_file
  # ---------------------------------------------------------------------------

  test "download_file copies remote stream to local file" do
    content = "fake xlsx bytes"
    remote  = StringIO.new(content)
    dest    = StringIO.new

    URI.stub(:open, ->(_url, _mode, &blk) { blk.call(remote) }) do
      @client.send(:download_file, "https://example.com/test.xlsx", dest)
    end

    assert_equal content, dest.string
  end

  # ---------------------------------------------------------------------------
  # parse_spreadsheet
  # ---------------------------------------------------------------------------

  test "parse_spreadsheet converts xlsx sheet to contract hashes" do
    headers   = SAMPLE_ROW.keys
    row_data  = SAMPLE_ROW.values

    sheet_mock = Minitest::Mock.new
    sheet_mock.expect(:row, headers, [ 1 ])
    sheet_mock.expect(:last_row, 2)
    sheet_mock.expect(:row, row_data, [ 2 ])

    xlsx_mock = Minitest::Mock.new
    xlsx_mock.expect(:sheet, sheet_mock, [ 0 ])

    Roo::Spreadsheet.stub(:open, xlsx_mock) do
      result = @client.send(:parse_spreadsheet, "/fake/path.xlsx")
      assert_equal 1, result.size
      assert_equal "12345", result[0]["external_id"]
    end

    assert_mock sheet_mock
    assert_mock xlsx_mock
  end

  # ---------------------------------------------------------------------------
  # stream_xlsx_resource
  # ---------------------------------------------------------------------------

  test "stream_xlsx_resource yields rows from downloaded file" do
    fake_rows = [ { "external_id" => "1" }, { "external_id" => "2" } ]
    collected = []

    @client.stub(:download_file, nil) do
      @client.stub(:stream_spreadsheet, ->(path, &blk) { fake_rows.each { |r| blk.call(r) } }) do
        @client.send(:stream_xlsx_resource, "https://example.com/test.xlsx") { |r| collected << r }
      end
    end

    assert_equal fake_rows, collected
  end

  # ---------------------------------------------------------------------------
  # count_rows_in_resource
  # ---------------------------------------------------------------------------

  test "count_rows_in_resource returns last_row minus header" do
    sheet_mock = Minitest::Mock.new
    sheet_mock.expect(:last_row, 51)

    xlsx_mock = Minitest::Mock.new
    xlsx_mock.expect(:sheet, sheet_mock, [ 0 ])

    @client.stub(:download_file, nil) do
      Roo::Spreadsheet.stub(:open, xlsx_mock) do
        count = @client.send(:count_rows_in_resource, "https://example.com/test.xlsx")
        assert_equal 50, count
      end
    end

    assert_mock sheet_mock
    assert_mock xlsx_mock
  end
end
