require "test_helper"
require_relative "../../../support/registo_comercial_fixtures"

class PublicContracts::PT::RegistoComercialTest < ActiveSupport::TestCase
  include RegistoComercialFixtures

  setup do
    @rc = PublicContracts::PT::RegistoComercial.new(pausa: 0)
  end

  # ── NIPC validation ────────────────────────────────────────────────────────
  test "pesquisar_por_nipc raises on short NIPC" do
    assert_raises(ArgumentError) { @rc.pesquisar_por_nipc("123") }
  end

  test "pesquisar_por_nipc raises on empty string" do
    assert_raises(ArgumentError) { @rc.pesquisar_por_nipc("") }
  end

  test "pesquisar_por_nipc strips non-digits before length check" do
    @rc.stub(:pesquisar, []) do
      result = @rc.pesquisar_por_nipc("123-456-789")
      assert_equal [], result
    end
  end

  test "pesquisar_por_nome raises on empty name" do
    assert_raises(ArgumentError) { @rc.pesquisar_por_nome("") }
  end

  test "pesquisar_por_nome raises on blank name" do
    assert_raises(ArgumentError) { @rc.pesquisar_por_nome("   ") }
  end

  # ── extrair_campos_ocultos ─────────────────────────────────────────────────
  test "extrair_campos_ocultos returns hash of hidden inputs" do
    campos = @rc.send(:extrair_campos_ocultos, HIDDEN_FIELDS_HTML)
    assert_equal "abc123", campos["__VIEWSTATE"]
    assert_equal "xyz789", campos["__EVENTVALIDATION"]
  end

  # ── extrair_resultados ─────────────────────────────────────────────────────
  test "extrair_resultados parses table rows" do
    results = @rc.send(:extrair_resultados, SEARCH_RESULTS_HTML)
    assert_equal 2, results.size
    assert_equal "509999001", results.first[:nipc]
    assert_equal "Construções Ferreira Lda", results.first[:entidade]
    assert results.first[:ligacao].include?("DetalhePublicacao")
  end

  test "extrair_resultados falls back to GridView selector" do
    results = @rc.send(:extrair_resultados, GRIDVIEW_HTML)
    assert results.size >= 1
  end

  test "extrair_resultados falls back to link scan when no table rows" do
    results = @rc.send(:extrair_resultados, FALLBACK_LINKS_HTML)
    assert results.size >= 1
    assert results.first[:ligacao].include?("Detalhe")
  end

  test "extrair_resultados skips all-empty rows" do
    results = @rc.send(:extrair_resultados, EMPTY_ROWS_HTML)
    assert_equal 0, results.size
  end

  # ── postback links ─────────────────────────────────────────────────────────
  test "extrair_linha_resultado marks postback links as :postback" do
    results = @rc.send(:extrair_resultados, POSTBACK_HTML)
    assert_equal 1, results.size
    assert_equal :postback, results.first[:ligacao]
  end

  # ── extrair_detalhe ────────────────────────────────────────────────────────
  test "extrair_detalhe parses NIPC" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_equal "509999001", detalhe[:nipc]
  end

  test "extrair_detalhe parses entidade" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_equal "Construções Ferreira Lda", detalhe[:entidade]
  end

  test "extrair_detalhe parses sede" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_equal "Rua das Obras 10, Porto", detalhe[:sede]
  end

  test "extrair_detalhe parses capital_social" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_equal "50.000 EUR", detalhe[:capital_social]
  end

  test "extrair_detalhe parses natureza_juridica" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_equal "Sociedade por Quotas", detalhe[:natureza_juridica]
  end

  test "extrair_detalhe extracts socios from lblConteudo" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_includes detalhe[:socios], "João Ferreira"
  end

  test "extrair_detalhe extracts gerentes from lblConteudo" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_includes detalhe[:gerentes], "Maria Silva"
  end

  test "extrair_detalhe builds structured people entries" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_HTML)
    assert_includes detalhe[:people], { name: "Maria Silva", role_type: "manager", role_label: "Gerente", tax_identifier: nil }
    assert_includes detalhe[:people], { name: "João Ferreira", role_type: "partner_shareholder", role_label: "Sócio", tax_identifier: nil }
  end

  test "extrair_detalhe uses fallback for corpo" do
    detalhe = @rc.send(:extrair_detalhe, CORPO_FALLBACK_HTML)
    refute_nil detalhe[:corpo]
  end

  test "extrair_detalhe returns hash for empty HTML" do
    detalhe = @rc.send(:extrair_detalhe, "<html></html>")
    assert_kind_of Hash, detalhe
  end

  # ── text extraction ────────────────────────────────────────────────────────
  test "extrair_socios finds name after socio pattern" do
    texto = "Sócios: António Rodrigues, NIF 111222333, com 100%."
    nomes = @rc.send(:extrair_socios, texto)
    assert_includes nomes, "António Rodrigues"
  end

  test "extrair_socios finds quota pattern" do
    texto = "quota pertencente a Carlos Mendes com 50%"
    nomes = @rc.send(:extrair_socios, texto)
    assert_includes nomes, "Carlos Mendes"
  end

  test "extrair_socios finds accionista pattern" do
    texto = "Accionistas: Sofia Pinto, detendo 1000 acções"
    nomes = @rc.send(:extrair_socios, texto)
    assert_includes nomes, "Sofia Pinto"
  end

  test "extrair_socios returns unique names" do
    texto = "Sócios: Manuel Costa, NIF 123. Sócios: Manuel Costa, NIF 123."
    nomes = @rc.send(:extrair_socios, texto)
    assert_equal 1, nomes.count { |n| n == "Manuel Costa" }
  end

  test "extrair_gerentes finds gerente pattern" do
    texto = "Gerentes: Rui Alves, residente em Lisboa."
    nomes = @rc.send(:extrair_gerentes, texto)
    assert_includes nomes, "Rui Alves"
  end

  test "extrair_gerentes finds administrador pattern" do
    texto = "Administradores: Pedro Gomes, portador do BI 12345"
    nomes = @rc.send(:extrair_gerentes, texto)
    assert_includes nomes, "Pedro Gomes"
  end

  test "extrair_gerentes finds presidente pattern" do
    texto = "Presidente: Lúcia Faria com funções de gestão"
    nomes = @rc.send(:extrair_gerentes, texto)
    assert_includes nomes, "Lúcia Faria"
  end

  test "extrair_gerentes returns unique names" do
    texto = "Gerentes: Rui Alves. Gerentes: Rui Alves."
    nomes = @rc.send(:extrair_gerentes, texto)
    assert_equal 1, nomes.count { |n| n == "Rui Alves" }
  end

  test "extrair_pessoas returns structured gerente and socio entries" do
    pessoas = @rc.send(:extrair_pessoas, "Sócios: João Ferreira, NIF 123456789. Gerentes: Maria Silva, residente em Porto.")

    assert_includes pessoas, { name: "João Ferreira", role_type: "partner_shareholder", role_label: "Sócio", tax_identifier: nil }
    assert_includes pessoas, { name: "Maria Silva", role_type: "manager", role_label: "Gerente", tax_identifier: nil }
  end

  # ── obter_detalhe guards ───────────────────────────────────────────────────
  test "obter_detalhe returns nil for nil" do
    assert_nil @rc.obter_detalhe(nil)
  end

  test "obter_detalhe returns nil for non-http link" do
    assert_nil @rc.obter_detalhe("javascript:void(0)")
  end

  # ── obter_detalhe body ────────────────────────────────────────────────────
  test "obter_detalhe fetches and parses detail HTML" do
    @rc.stub(:obter_pagina, DETAIL_HTML) do
      detalhe = @rc.obter_detalhe("http://publicacoes.mj.pt/Detalhe.aspx?id=1")
      assert_equal "509999001", detalhe[:nipc]
    end
  end

  # ── pesquisar_por_nome body ───────────────────────────────────────────────
  test "pesquisar_por_nome delegates to pesquisar with nome" do
    @rc.stub(:pesquisar, [ { nipc: "123456789", entidade: "Empresa Teste" } ]) do
      result = @rc.pesquisar_por_nome("Empresa Teste")
      assert_equal 1, result.size
    end
  end

  # ── investigar ────────────────────────────────────────────────────────────
  test "investigar returns publications with details for http links" do
    pub_with_link    = { nipc: "123456789", resumo: "Test Pub",   ligacao: "http://example.com/Detalhe" }
    pub_without_link = { nipc: "123456789", resumo: "Other Pub",  ligacao: nil }
    pubs = [ pub_with_link, pub_without_link ]
    detalhe = { entidade: "Test Empresa", nipc: "123456789" }
    @rc.stub(:pesquisar_por_nipc, pubs) do
      @rc.stub(:obter_detalhe, detalhe) do
        result = @rc.investigar("123456789")
        assert_equal 2, result.size
        assert_equal detalhe, result.first[:detalhe]
        assert_nil result.last[:detalhe]
      end
    end
  end

  # ── dormir ────────────────────────────────────────────────────────────────
  test "dormir sleeps when pausa is positive" do
    rc = PublicContracts::PT::RegistoComercial.new(pausa: 1)
    sleep_called = false
    rc.stub(:sleep, ->(_n) { sleep_called = true }) do
      rc.send(:dormir)
    end
    assert sleep_called, "expected sleep to be called when pausa > 0"
  end

  # ── guardar_biscoitos / montar_biscoitos ──────────────────────────────────
  test "guardar_biscoitos stores cookies from Set-Cookie headers" do
    rc = PublicContracts::PT::RegistoComercial.new(pausa: 0)
    fake_resp = Object.new
    fake_resp.define_singleton_method(:get_fields) { |_| [ "session=abc123; Path=/", "token=xyz; HttpOnly" ] }
    rc.send(:guardar_biscoitos, fake_resp)
    cookies = rc.send(:montar_biscoitos)
    assert_includes cookies, "session=abc123"
    assert_includes cookies, "token=xyz"
  end

  test "montar_biscoitos returns empty string when no cookies" do
    rc = PublicContracts::PT::RegistoComercial.new(pausa: 0)
    assert_equal "", rc.send(:montar_biscoitos)
  end

  # ── enviar_formulario redirect ────────────────────────────────────────────
  test "enviar_formulario follows HTTP redirect" do
    redirect_resp = Object.new
    redirect_resp.define_singleton_method(:is_a?) { |klass| klass == Net::HTTPRedirection }
    redirect_resp.define_singleton_method(:[]) { |_key| "/pesquisa_resultado.aspx" }

    final_html = "<html><body>resultado</body></html>"
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=)      { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request)       { |_| redirect_resp }

    Net::HTTP.stub(:new, fake_http) do
      @rc.stub(:guardar_biscoitos, nil) do
        @rc.stub(:obter_pagina, final_html) do
          result = @rc.send(:enviar_formulario, "https://publicacoes.mj.pt/pesquisa.aspx", {})
          assert_equal final_html, result
        end
      end
    end
  end

  # ── extrair_resultados GridView fallback ─────────────────────────────────
  test "extrair_resultados GridView fallback picks up rows with GridView id" do
    results = @rc.send(:extrair_resultados, GRIDVIEW_FALLBACK_HTML)
    assert results.size >= 1
    assert results.any? { |r| r[:nipc] == "509999002" }
  end

  # ── extrair_detalhe distrito, concelho and objecto ───────────────────────
  test "extrair_detalhe parses distrito, concelho, and objecto fields" do
    detalhe = @rc.send(:extrair_detalhe, DETAIL_EXTENDED_HTML)
    assert_equal "Porto",                  detalhe[:distrito]
    assert_equal "Matosinhos",             detalhe[:concelho]
    assert_equal "Prestação de serviços",  detalhe[:objecto]
  end

  # ── ConsultaEmLote ────────────────────────────────────────────────────────
  test "ConsultaEmLote initializes with lista_nipc" do
    lote = PublicContracts::PT::ConsultaEmLote.new(lista_nipc: [ "123456789" ])
    assert_instance_of PublicContracts::PT::ConsultaEmLote, lote
  end

  test "ConsultaEmLote executar gathers publications and writes JSON" do
    require "tempfile"
    lote = PublicContracts::PT::ConsultaEmLote.new(lista_nipc: [ "509999001" ])
    pubs = [ { ligacao: "http://example.com/Detalhe", entidade: "Test Empresa" } ]
    detalhe = { socios: [ "Ana Silva" ], gerentes: [], capital_social: "10.000 EUR", sede: "Lisboa", natureza_juridica: "Lda" }
    outfile = Tempfile.new([ "resultados", ".json" ])
    outfile.close
    lote.instance_variable_get(:@rc).stub(:pesquisar_por_nipc, pubs) do
      lote.instance_variable_get(:@rc).stub(:obter_detalhe, detalhe) do
        result = lote.executar(ficheiro_saida: outfile.path)
        assert result.key?("509999001")
        assert_equal [ "Ana Silva" ], result["509999001"][:socios]
      end
    end
  ensure
    outfile&.unlink
  end

  test "ConsultaEmLote carregar_csv loads NIPCs from CSV file" do
    require "tempfile"
    csv_content = "NIPC Adjudicatário,Valor\n509999001,1000\n509999002,2000\ninvalid,0\n"
    csv_file = Tempfile.new([ "base", ".csv" ])
    csv_file.write(csv_content)
    csv_file.close
    lote = PublicContracts::PT::ConsultaEmLote.new(ficheiro_csv: csv_file.path)
    nipcs = lote.instance_variable_get(:@nipcs)
    assert_includes nipcs, "509999001"
    assert_includes nipcs, "509999002"
    refute_includes nipcs, "invalid"
  ensure
    csv_file&.unlink
  end

  test "ConsultaEmLote executar handles errors gracefully" do
    lote = PublicContracts::PT::ConsultaEmLote.new(lista_nipc: [ "000000000" ])
    lote.instance_variable_get(:@rc).stub(:pesquisar_por_nipc, ->(_nipc) { raise StandardError, "network error" }) do
      require "tempfile"
      outfile = Tempfile.new([ "resultados", ".json" ])
      outfile.close
      result = lote.executar(ficheiro_saida: outfile.path)
      assert_equal({}, result)
    ensure
      outfile&.unlink
    end
  end

  # ── Cruzamento ────────────────────────────────────────────────────────────
  test "Cruzamento detectar_ligacoes finds people shared across entities" do
    require "tempfile"
    registo = {
      "123456789" => { socios: [ "João Silva" ], gerentes: [], entidade: "Empresa A" },
      "987654321" => { socios: [ "João Silva" ], gerentes: [], entidade: "Empresa B" }
    }.to_json
    base_csv = "nipc,valor\n123456789,100\n"

    base_f    = Tempfile.new([ "base", ".csv" ])
    registo_f = Tempfile.new([ "registo", ".json" ])
    base_f.write(base_csv)
    registo_f.write(registo)
    base_f.close
    registo_f.close

    cruz = PublicContracts::PT::Cruzamento.new(
      ficheiro_base:    base_f.path,
      ficheiro_registo: registo_f.path
    )
    alertas = cruz.detectar_ligacoes
    assert alertas.size >= 1
    pessoa = alertas.find { |a| a[:pessoa].include?("silva") || a[:pessoa].include?("João") || a[:pessoa].include?("joao") }
    assert_not_nil pessoa
  ensure
    base_f&.unlink
    registo_f&.unlink
  end

  test "Cruzamento detectar_ligacoes returns empty when no shared persons" do
    require "tempfile"
    registo = {
      "123456789" => { socios: [ "Ana Lopes" ], gerentes: [], entidade: "Empresa A" },
      "987654321" => { socios: [ "Pedro Costa" ], gerentes: [], entidade: "Empresa B" }
    }.to_json
    base_csv = "nipc,valor\n123456789,100\n"

    base_f    = Tempfile.new([ "base2", ".csv" ])
    registo_f = Tempfile.new([ "registo2", ".json" ])
    base_f.write(base_csv)
    registo_f.write(registo)
    base_f.close
    registo_f.close

    cruz = PublicContracts::PT::Cruzamento.new(
      ficheiro_base:    base_f.path,
      ficheiro_registo: registo_f.path
    )
    assert_equal [], cruz.detectar_ligacoes
  ensure
    base_f&.unlink
    registo_f&.unlink
  end
end
