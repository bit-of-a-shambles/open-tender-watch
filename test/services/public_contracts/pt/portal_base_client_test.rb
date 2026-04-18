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
    "concorrentes"           => [ "123456789 - Empresa ABC, Lda", "987654321 - Empresa XYZ, SA" ],
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

  test "parse_bidders parses bidders with tax identifiers" do
    result = @client.send(:parse_bidders, [ "123456789 - Empresa ABC, Lda", "987654321 - Empresa XYZ, SA" ])
    assert_equal 2, result.size
    assert_equal "123456789", result.first["tax_identifier"]
    assert_equal "Empresa XYZ, SA", result.last["name"]
  end

  test "parse_bidders keeps raw label when tax identifier is missing" do
    result = @client.send(:parse_bidders, [ "--EBSCO Information Services S.L.U." ])
    assert_equal 1, result.size
    assert_nil result.first["tax_identifier"]
    assert_equal "EBSCO Information Services S.L.U.", result.first["name"]
    assert_equal "--EBSCO Information Services S.L.U.", result.first["raw_label"]
  end

  test "parse_bidder_count returns number of bidder entries" do
    assert_equal 2, @client.send(:parse_bidder_count, [ "A", "B" ])
    assert_nil @client.send(:parse_bidder_count, nil)
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
    assert_equal 2,             result["bidder_count"]
    assert_equal 2,             result["bidders"].size
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

  test "normalize_json_row unwraps scalar arrays from BASE JSON export" do
    payload = {
      "idcontrato" => "12345",
      "objectoContrato" => "Contrato JSON",
      "tipoprocedimento" => "Concurso público",
      "tipoContrato" => [ "Aquisição de bens móveis" ],
      "adjudicante" => [ "504595067 - Câmara Municipal de Lisboa" ],
      "adjudicatarios" => [ "123456789 - Empresa ABC, Lda" ],
      "concorrentes" => [ "123456789 - Empresa ABC, Lda", "987654321 - Empresa XYZ, SA" ],
      "dataPublicacao" => "2024-03-15",
      "dataCelebracaoContrato" => "2024-03-10",
      "precoBaseProcedimento" => "5000.0",
      "precoContratual" => "4800.0",
      "PrecoTotalEfetivo" => "4900.0",
      "cpv" => [ "90910000-9 - Serviços de limpeza" ],
      "localExecucao" => [ "PT170" ]
    }

    result = @client.send(:normalize_json_row, payload)

    assert_equal "12345", result["external_id"]
    assert_equal "Aquisição de bens móveis", result["contract_type"]
    assert_equal "504595067", result["contracting_entity"]["tax_identifier"]
    assert_equal "90910000", result["cpv_code"]
    assert_equal "PT170", result["location"]
    assert_equal 2, result["bidder_count"]
  end

  # ---------------------------------------------------------------------------
  # fetch_resources
  # ---------------------------------------------------------------------------

  test "fetch_resources returns xlsx resources when no zip variant exists" do
    Net::HTTP.stub(:get_response, fake_http_success(SAMPLE_DATASET_RESPONSE)) do
      resources = @client.send(:fetch_resources)
      assert_equal 2, resources.size
      assert_equal [ "xlsx", "xlsx" ], resources.map { |r| r["format"].downcase }
    end
  end

  test "fetch_resources returns empty array when API fails" do
    Net::HTTP.stub(:get_response, fake_http_error) do
      assert_equal [], @client.send(:fetch_resources)
    end
  end

  test "fetch_resources prefers zip when both zip and xlsx exist for a year" do
    resources = [
      { "title" => "contratos2024.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2024.xlsx" },
      { "title" => "contratos2024.zip", "format" => "zip", "url" => "https://example.com/contratos2024.zip" }
    ]

    @client.stub(:get, { "resources" => resources }) do
      fetched = @client.send(:fetch_resources)
      assert_equal 1, fetched.size
      assert_equal "zip", fetched.first["format"]
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
      @client.stub(:stream_resource, ->(res, &blk) { rows.each { |r| blk.call(r) } }) do
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
      @client.stub(:stream_resource, ->(res, &blk) { rows.each { |r| blk.call(r) } }) do
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
  # prefetch_files
  # ---------------------------------------------------------------------------

  test "prefetch_files downloads missing files and skips cached ones" do
    resources = [
      { "title" => "contratos2023.zip", "format" => "zip", "url" => "https://example.com/contratos2023.zip",
        "filesize" => 5_242_880 },
      { "title" => "contratos2024.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2024.xlsx",
        "filesize" => 3_145_728 }
    ]
    client = PublicContracts::PT::PortalBaseClient.new("years" => [ 2023, 2024 ])
    messages = []

    # 2023: not valid cached → downloads. 2024: valid cached → skip.
    valid_stub = ->(path) { path.to_s.include?("2024") }

    client.stub(:fetch_resources, resources) do
      client.stub(:download_with_retry, nil) do
        client.stub(:cached_resource_valid?, valid_stub) do
          File.stub(:size, 5_242_880) do
            client.prefetch_files { |msg| messages << msg }
          end
        end
      end
    end

    assert messages.any? { |m| m.include?("2023") && m.include?("downloading") }
    assert messages.any? { |m| m.include?("2024") && m.include?("already cached") }
  end

  test "prefetch_files deletes 0-byte file before re-downloading" do
    resources = [
      { "title" => "contratos2023.zip", "format" => "zip", "url" => "https://example.com/contratos2023.zip",
        "filesize" => 0 }
    ]
    client   = PublicContracts::PT::PortalBaseClient.new("years" => [ 2023 ])
    deleted  = []
    messages = []

    client.stub(:fetch_resources, resources) do
      client.stub(:download_with_retry, nil) do
        client.stub(:cached_resource_valid?, false) do
          File.stub(:exist?, true) do
            File.stub(:delete, ->(p) { deleted << p }) do
              File.stub(:size, 0) do
                client.prefetch_files { |msg| messages << msg }
              end
            end
          end
        end
      end
    end

    assert_equal 1, deleted.size, "should delete the 0-byte cached file"
    assert messages.any? { |m| m.include?("downloading") }
  end

  # ---------------------------------------------------------------------------
  # each_contract
  # ---------------------------------------------------------------------------

  test "each_contract yields all rows from every configured year file" do
    resources = [
      { "title" => "contratos2024.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2024.xlsx" },
      { "title" => "contratos2025.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2025.xlsx" }
    ]
    rows_2024 = [ { "external_id" => "1" }, { "external_id" => "2" } ]
    rows_2025 = [ { "external_id" => "3" } ]

    client = PublicContracts::PT::PortalBaseClient.new("years" => [ 2024, 2025 ])
    client.stub(:fetch_resources, resources) do
      client.stub(:stream_resource, ->(res, &blk) {
        data = res["url"].include?("2024") ? rows_2024 : rows_2025
        data.each { |r| blk.call(r) }
      }) do
        collected = []
        client.each_contract { |row| collected << row }
        assert_equal 3, collected.size
        assert_equal [ "1", "2", "3" ], collected.map { |r| r["external_id"] }
      end
    end
  end

  test "each_contract skips year files not in config" do
    resources = [
      { "title" => "contratos2024.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2024.xlsx" },
      { "title" => "contratos2023.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2023.xlsx" }
    ]
    rows_2024 = [ { "external_id" => "10" } ]

    # @client is configured for 2024 only
    @client.stub(:fetch_resources, resources) do
      @client.stub(:stream_resource, ->(res, &blk) {
        rows_2024.each { |r| blk.call(r) } if res["url"].include?("2024")
      }) do
        collected = []
        @client.each_contract { |row| collected << row }
        assert_equal 1, collected.size
        assert_equal "10", collected.first["external_id"]
      end
    end
  end

  test "each_contract returns an enumerator when no block given" do
    @client.stub(:fetch_resources, []) do
      assert_kind_of Enumerator, @client.each_contract
    end
  end

  test "each_contract yields rows in ascending year order" do
    resources = [
      { "title" => "contratos2025.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2025.xlsx" },
      { "title" => "contratos2024.xlsx", "format" => "xlsx", "url" => "https://example.com/contratos2024.xlsx" }
    ]
    order = []
    client = PublicContracts::PT::PortalBaseClient.new("years" => [ 2024, 2025 ])
    client.stub(:fetch_resources, resources) do
      client.stub(:stream_resource, ->(res, &blk) {
        year = res["url"][/\d{4}/].to_i
        blk.call({ "external_id" => year.to_s })
        order << year
      }) do
        client.each_contract { |_| }
      end
    end
    assert_equal [ 2024, 2025 ], order
  end

  # ---------------------------------------------------------------------------
  # total_count
  # ---------------------------------------------------------------------------

  test "total_count estimates rows from filesize without downloading" do
    # BYTES_PER_ROW_ESTIMATE = 200; filesize 25_000 → 125 rows
    resources = [ { "title" => "contratos2024.xlsx", "format" => "xlsx",
                    "url"   => "https://example.com/contratos2024.xlsx",
                    "filesize" => 25_000 } ]
    @client.stub(:fetch_resources, resources) do
      assert_equal 125, @client.total_count
    end
  end

  test "total_count ignores years not in config" do
    resources = [
      { "title" => "contratos2024.xlsx", "format" => "xlsx",
        "url" => "https://example.com/contratos2024.xlsx", "filesize" => 25_000 },
      { "title" => "contratos2023.xlsx", "format" => "xlsx",
        "url" => "https://example.com/contratos2023.xlsx", "filesize" => 50_000 }
    ]
    @client.stub(:fetch_resources, resources) do
      # @client is configured for 2024 only, so 2023 should not be counted
      assert_equal 125, @client.total_count
    end
  end

  test "total_count returns 0 when no matching year found" do
    @client.stub(:fetch_resources, []) do
      assert_equal 0, @client.total_count
    end
  end

  # ---------------------------------------------------------------------------
  # cached_resource_valid?
  # ---------------------------------------------------------------------------

  test "cached_resource_valid? returns false when file does not exist" do
    File.stub(:exist?, false) do
      refute @client.send(:cached_resource_valid?, "/tmp/missing.zip")
    end
  end

  test "cached_resource_valid? returns false when file is 0 bytes" do
    File.stub(:exist?, true) do
      File.stub(:size, 0) do
        refute @client.send(:cached_resource_valid?, "/tmp/empty.zip")
      end
    end
  end

  test "cached_resource_valid? returns true when file exists and non-zero" do
    File.stub(:exist?, true) do
      File.stub(:size, 1024) do
        assert @client.send(:cached_resource_valid?, "/tmp/good.zip")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # download_with_retry
  # ---------------------------------------------------------------------------

  test "download_with_retry succeeds on first attempt" do
    dest = Tempfile.new([ "test", ".xlsx" ])
    dest.write("data"); dest.flush
    @client.stub(:download_file, nil) do
      @client.stub(:cached_resource_valid?, true) do
        assert_nothing_raised { @client.send(:download_with_retry, "https://example.com/x.xlsx", dest.path) }
      end
    end
  ensure
    dest&.unlink
  end

  test "download_with_retry retries on ECONNRESET and succeeds" do
    call_count = 0
    dest       = "/tmp/retry_test.xlsx"
    File.delete(dest) if File.exist?(dest)

    flaky_download = lambda do |_url, _file|
      call_count += 1
      raise Errno::ECONNRESET, "Connection reset" if call_count < 2
    end

    @client.stub(:download_file, flaky_download) do
      @client.stub(:cached_resource_valid?, ->(path) { call_count >= 2 }) do
        @client.send(:download_with_retry, "https://example.com/x.xlsx", dest)
      end
    end

    assert_equal 2, call_count, "should retry once after ECONNRESET"
  ensure
    File.delete(dest) if File.exist?(dest)
  end

  test "download_with_retry raises after all attempts exhausted" do
    always_reset = ->(_url, _file) { raise Errno::ECONNRESET, "reset" }

    @client.stub(:download_file, always_reset) do
      @client.stub(:cached_resource_valid?, false) do
        File.stub(:exist?, false) do
          assert_raises(Errno::ECONNRESET) do
            @client.send(:download_with_retry, "https://example.com/x.xlsx", "/tmp/never.xlsx", attempts: 3)
          end
        end
      end
    end
  end

  test "download_with_retry raises RuntimeError when download succeeds but file is empty" do
    # download_file completes without error but writes nothing (e.g. server returns empty body)
    @client.stub(:download_file, nil) do
      @client.stub(:cached_resource_valid?, false) do
        File.stub(:exist?, true) do
          File.stub(:delete, nil) do
            err = assert_raises(RuntimeError) do
              @client.send(:download_with_retry, "https://example.com/x.xlsx", "/tmp/empty.xlsx", attempts: 1)
            end
            assert_match(/Empty file after download/, err.message)
          end
        end
      end
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
    headers  = SAMPLE_ROW.keys
    row_data = SAMPLE_ROW.values

    cell_struct  = Struct.new(:value)
    header_cells = headers.map { |h| cell_struct.new(h) }
    data_cells   = row_data.map { |v| cell_struct.new(v) }

    xlsx_obj = Object.new
    xlsx_obj.define_singleton_method(:each_row_streaming) do |pad_cells: false, &blk|
      blk.call(header_cells)
      blk.call(data_cells)
    end

    Roo::Spreadsheet.stub(:open, xlsx_obj) do
      result = @client.send(:parse_spreadsheet, "/fake/path.xlsx")
      assert_equal 1, result.size
      assert_equal "12345", result[0]["external_id"]
    end
  end

  test "each_json_object parses objects from read-only io chunks" do
    read_only_io = Class.new do
      def initialize(payload)
        @payload = payload
        @offset = 0
      end

      def read(length)
        return nil if @offset >= @payload.length

        chunk = @payload[@offset, length]
        @offset += chunk.length
        chunk
      end
    end.new(%([
      {"idcontrato":"1","adjudicante":"504595067 - Câmara Municipal de Lisboa","objectoContrato":"A"},
      {"idcontrato":"2","adjudicante":"504595067 - Câmara Municipal de Lisboa","objectoContrato":"B"}
    ]))

    payloads = []
    @client.send(:each_json_object, read_only_io) { |payload| payloads << payload }

    assert_equal 2, payloads.size
    assert_equal "1", payloads.first["idcontrato"]
    assert_equal "2", payloads.last["idcontrato"]
  end

  test "each_json_object handles escaped quotes and backslashes inside strings" do
    payload = [
      {
        "idcontrato" => "1",
        "adjudicante" => "504595067 - Câmara Municipal de Lisboa",
        "objectoContrato" => "Caminho \\ rede e \"aspas\""
      }
    ].to_json

    read_only_io = Class.new do
      def initialize(payload)
        @payload = payload
        @offset = 0
      end

      def read(length)
        return nil if @offset >= @payload.length

        chunk = @payload[@offset, length]
        @offset += chunk.length
        chunk
      end
    end.new(payload)

    payloads = []
    @client.send(:each_json_object, read_only_io) { |payload| payloads << payload }

    assert_equal 1, payloads.size
    assert_equal "Caminho \\ rede e \"aspas\"", payloads.first["objectoContrato"]
  end

  # ---------------------------------------------------------------------------
  # stream_resource
  # ---------------------------------------------------------------------------

  test "stream_resource yields rows from downloaded xlsx file" do
    fake_rows = [ { "external_id" => "1" }, { "external_id" => "2" } ]
    collected = []
    resource = { "format" => "xlsx", "url" => "https://example.com/test.xlsx" }

    @client.stub(:cached_resource_valid?, false) do
      @client.stub(:download_with_retry, nil) do
        @client.stub(:stream_spreadsheet, ->(path, &blk) { fake_rows.each { |r| blk.call(r) } }) do
          @client.send(:stream_resource, resource) { |r| collected << r }
        end
      end
    end

    assert_equal fake_rows, collected
  end

  test "stream_resource uses cached xlsx file and skips download when cache exists" do
    fake_rows = [ { "external_id" => "3" } ]
    collected = []
    resource = { "format" => "xlsx", "url" => "https://example.com/contratos2020.xlsx" }

    @client.stub(:cached_resource_valid?, true) do
      @client.stub(:stream_spreadsheet, ->(path, &blk) { fake_rows.each { |r| blk.call(r) } }) do
        @client.send(:stream_resource, resource) { |r| collected << r }
      end
    end

    assert_equal fake_rows, collected
  end

  test "stream_resource yields rows from cached zip resource" do
    fake_rows = [ { "external_id" => "zip-1" } ]
    collected = []
    resource = { "format" => "zip", "url" => "https://example.com/contratos2024.zip" }

    @client.stub(:cached_resource_valid?, true) do
      @client.stub(:stream_json_zip_resource, ->(_path, &blk) { fake_rows.each { |row| blk.call(row) } }) do
        @client.send(:stream_resource, resource) { |row| collected << row }
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
    resource = { "format" => "xlsx", "url" => "https://example.com/test.xlsx" }

    @client.stub(:cached_resource_valid?, false) do
      @client.stub(:download_with_retry, nil) do
        Roo::Spreadsheet.stub(:open, xlsx_mock) do
          count = @client.send(:count_rows_in_resource, resource)
          assert_equal 50, count
        end
      end
    end

    assert_mock sheet_mock
    assert_mock xlsx_mock
  end

  test "count_rows_in_resource delegates zip files to json row counter" do
    resource = { "format" => "zip", "url" => "https://example.com/test.zip" }

    @client.stub(:cached_resource_valid?, true) do
      @client.stub(:count_json_rows_in_zip, 7) do
        assert_equal 7, @client.send(:count_rows_in_resource, resource)
      end
    end
  end

  test "stream_json_zip_resource yields normalized rows from first json entry" do
    payload = %([{"idcontrato":"12345","adjudicante":"504595067 - Câmara Municipal de Lisboa","objectoContrato":"Contrato ZIP","tipoprocedimento":"Ajuste Direto","tipoContrato":"Prestação de Serviços","dataPublicacao":"2024-03-15","dataCelebracaoContrato":"2024-03-10","precoBaseProcedimento":"5000.0","precoContratual":"4800.0","PrecoTotalEfetivo":"4900.0","cpv":"90910000-9 - Serviços de limpeza","localExecucao":"PT170","adjudicatarios":"123456789 - Empresa ABC, Lda","concorrentes":["123456789 - Empresa ABC, Lda"]}])
    entry = Object.new
    entry.define_singleton_method(:get_input_stream) { StringIO.new(payload) }

    zip_file = Object.new
    zip_file.define_singleton_method(:glob) { |_pattern| [ entry ] }
    zip_file.define_singleton_method(:first) { nil }

    rows = []
    Zip::File.stub(:open, ->(_path, &blk) { blk.call(zip_file) }) do
      @client.send(:stream_json_zip_resource, "/tmp/contracts.zip") { |row| rows << row }
    end

    assert_equal 1, rows.size
    assert_equal "12345", rows.first["external_id"]
    assert_equal 1, rows.first["bidder_count"]
  end

  test "count_json_rows_in_zip counts streamed rows" do
    @client.stub(:stream_json_zip_resource, ->(_path, &blk) { 3.times { blk.call({}) } }) do
      assert_equal 3, @client.send(:count_json_rows_in_zip, "/tmp/contracts.zip")
    end
  end
end
