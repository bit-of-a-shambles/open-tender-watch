# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "csv"
require "date"
require "nokogiri"

module PublicContracts
  module PT
    class RegistoComercial
      DOMINIO        = "publicacoes.mj.pt"
      URL_PESQUISA   = "https://#{DOMINIO}/pesquisa.aspx"
      URL_DETALHE    = "https://#{DOMINIO}/DetalhePublicacao.aspx"
      AGENTE         = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " \
                       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

      TIPOS = {
        todos:             "rblTipo_0",
        registo_comercial: "rblTipo_1",
        avisos:            "rblTipo_2",
        associacoes:       "rblTipo_3",
        solidariedade:     "rblTipo_4",
        pais:              "rblTipo_5",
        fundacoes:         "rblTipo_6"
      }.freeze

      def initialize(pausa: 2)
        @pausa  = pausa
        @sessao = {}
      end

      def pesquisar_por_nipc(nipc, tipo: :todos)
        nipc = nipc.to_s.strip.gsub(/\D/, "")
        raise ArgumentError, "NIPC deve ter 9 dígitos" unless nipc.length == 9
        pesquisar(nipc: nipc, tipo: tipo)
      end

      def pesquisar_por_nome(nome, tipo: :todos)
        nome = nome.to_s.strip
        raise ArgumentError, "Nome vazio" if nome.empty?
        pesquisar(nome: nome, tipo: tipo)
      end

      def obter_detalhe(ligacao)
        return nil unless ligacao&.start_with?("http")
        dormir
        html = obter_pagina(ligacao)
        extrair_detalhe(html)
      end

      def investigar(nipc)
        publicacoes = pesquisar_por_nipc(nipc)
        publicacoes.each_with_index do |pub, i|
          next unless pub[:ligacao]
          $stderr.print "\r  A ler publicação #{i + 1}/#{publicacoes.size}..."
          detalhe = obter_detalhe(pub[:ligacao])
          pub[:detalhe] = detalhe if detalhe
        end
        $stderr.puts
        publicacoes
      end

      private

      def dormir
        sleep(@pausa) if @pausa > 0
      end

      def criar_ligacao(url_texto)
        uri  = URI(url_texto)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = true
        http.open_timeout = 15
        http.read_timeout = 30
        [ uri, http ]
      end

      def obter_pagina(url_texto)
        uri, http = criar_ligacao(url_texto)
        pedido = Net::HTTP::Get.new(uri)
        pedido["User-Agent"] = AGENTE
        pedido["Cookie"]     = montar_biscoitos if @sessao.any?
        resposta = http.request(pedido)
        guardar_biscoitos(resposta)
        resposta.body.force_encoding("utf-8")
      end

      def enviar_formulario(url_texto, campos)
        uri, http = criar_ligacao(url_texto)
        pedido = Net::HTTP::Post.new(uri)
        pedido["User-Agent"]   = AGENTE
        pedido["Content-Type"] = "application/x-www-form-urlencoded"
        pedido["Cookie"]       = montar_biscoitos if @sessao.any?
        pedido.body            = URI.encode_www_form(campos)
        resposta = http.request(pedido)
        guardar_biscoitos(resposta)

        if resposta.is_a?(Net::HTTPRedirection)
          novo_url = resposta["Location"]
          novo_url = "https://#{DOMINIO}#{novo_url}" unless novo_url.start_with?("http")
          return obter_pagina(novo_url)
        end

        resposta.body.force_encoding("utf-8")
      end

      def guardar_biscoitos(resposta)
        Array(resposta.get_fields("Set-Cookie")).each do |biscoito|
          chave, valor = biscoito.split(";").first.split("=", 2)
          @sessao[chave.strip] = valor.to_s.strip
        end
      end

      def montar_biscoitos
        @sessao.map { |k, v| "#{k}=#{v}" }.join("; ")
      end

      def pesquisar(nipc: nil, nome: nil, tipo: :todos)
        html_inicial   = obter_pagina(URL_PESQUISA)
        campos_ocultos = extrair_campos_ocultos(html_inicial)
        dormir
        tipo_radio = TIPOS.fetch(tipo, TIPOS[:todos])
        dados = campos_ocultos.merge(
          "ctl00$ContentPlaceHolder1$txtNIPC"      => nipc.to_s,
          "ctl00$ContentPlaceHolder1$txtEntidade"  => nome.to_s,
          "ctl00$ContentPlaceHolder1$ddlDistrito"  => "",
          "ctl00$ContentPlaceHolder1$ddlConcelho"  => "",
          "ctl00$ContentPlaceHolder1$txtDataDe"    => "",
          "ctl00$ContentPlaceHolder1$txtDataAte"   => "",
          "ctl00$ContentPlaceHolder1$rblTipo"      => tipo_radio,
          "ctl00$ContentPlaceHolder1$btnPesquisar" => "Pesquisar"
        )
        html_resultado = enviar_formulario(URL_PESQUISA, dados)
        extrair_resultados(html_resultado)
      end

      def extrair_campos_ocultos(html)
        doc    = Nokogiri::HTML(html)
        campos = {}
        doc.css('input[type="hidden"]').each do |input|
          nome  = input["name"]
          valor = input["value"].to_s
          campos[nome] = valor if nome
        end
        campos
      end

      def extrair_resultados(html)
        doc        = Nokogiri::HTML(html)
        resultados = []

        doc.css("table tr").each do |linha|
          celulas = linha.css("td")
          next if celulas.empty?
          ligacao_el = linha.at_css('a[href*="Detalhe"]') ||
                       linha.at_css('a[href*="detalhe"]')
          textos = celulas.map { |c| c.text.strip }
          pub    = extrair_linha_resultado(textos, ligacao_el)
          resultados << pub if pub
        end

        if resultados.empty?
          doc.css('[id*="GridView"] tr, [id*="grd"] tr, [id*="grid"] tr').each do |linha|
            celulas = linha.css("td")
            next if celulas.empty?
            ligacao_el = linha.at_css("a[href]")
            textos     = celulas.map { |c| c.text.strip }
            pub        = extrair_linha_resultado(textos, ligacao_el)
            resultados << pub if pub
          end
        end

        if resultados.empty?
          doc.css('a[href*="Detalhe"]').each do |a|
            href = a["href"].to_s
            href = "https://#{DOMINIO}/#{href}" unless href.start_with?("http")
            resultados << { resumo: a.text.strip, ligacao: href }
          end
        end

        $stderr.puts "  Encontradas #{resultados.size} publicações"
        resultados
      end

      def extrair_linha_resultado(textos, ligacao_el)
        return nil if textos.all?(&:empty?)
        ligacao = nil
        if ligacao_el
          href = ligacao_el["href"].to_s
          if href.include?("javascript:__doPostBack")
            ligacao = :postback
          else
            href = "https://#{DOMINIO}/#{href}" unless href.start_with?("http")
            ligacao = href
          end
        end
        {
          nipc:     textos[0],
          entidade: textos[1],
          data:     textos[2],
          tipo:     textos[3],
          resumo:   textos.reject(&:empty?).join(" | "),
          ligacao:  ligacao
        }
      end

      def extrair_detalhe(html)
        doc     = Nokogiri::HTML(html)
        detalhe = {}

        doc.css("table tr").each do |linha|
          celulas = linha.css("td, th")
          next unless celulas.size >= 2
          etiqueta = celulas[0].text.strip.downcase.gsub(/[:\s]+$/, "")
          valor    = celulas[1].text.strip

          case etiqueta
          when /nif|nipc|matr[ií]cula/        then detalhe[:nipc]              = valor.gsub(/\D/, "")
          when /entidade|firma|denomina/       then detalhe[:entidade]          = valor
          when /data.*publica/                 then detalhe[:data_publicacao]   = valor
          when /natureza/                      then detalhe[:natureza_juridica] = valor
          when /sede/                          then detalhe[:sede]              = valor
          when /distrito/                      then detalhe[:distrito]          = valor
          when /concelho/                      then detalhe[:concelho]          = valor
          when /capital/                       then detalhe[:capital_social]    = valor
          when /objec?to/                      then detalhe[:objecto]           = valor
          end
        end

        corpo = doc.css('[id*="lblConteudo"], [id*="lblTexto"], [id*="conteudo"]')
                   .map(&:text).join("\n").strip

        if corpo.empty?
          corpo = doc.css("td, div, p")
                     .map { |el| el.text.strip }
                     .select { |t| t.length > 100 }
                     .max_by(&:length).to_s
        end

        detalhe[:corpo] = corpo unless corpo.empty?

        if corpo.length > 0
          detalhe[:socios]   = extrair_socios(corpo)
          detalhe[:gerentes] = extrair_gerentes(corpo)
          detalhe[:people]   = extrair_pessoas(corpo)
        end

        detalhe
      end

      def extrair_pessoas(texto)
        build_people_entries(extrair_gerentes(texto), role_type: "manager", role_label: "Gerente") +
          build_people_entries(extrair_socios(texto), role_type: "partner_shareholder", role_label: "Sócio")
      end

      def extrair_socios(texto)
        nomes   = []
        padroes = [
          /s[óo]cios?[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /quota[s]?\s+(?:de|pertencente[s]?\s+a)\s+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /accion[ií]sta[s]?[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /titular(?:es)?[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /parte[s]?\s+social?\s+(?:de|a)\s+([A-ZÀ-Ú][^,;\.]{5,60})/i
        ]
        padroes.each do |padrao|
          texto.scan(padrao).each do |captura|
            nome = captura[0].strip.sub(/\s*,?\s*(?:NIF|NIPC|com|detendo|titular|portador).*$/i, "").strip
            nomes << nome if nome.length > 3 && nome.length < 80
          end
        end
        nomes.uniq
      end

      def extrair_gerentes(texto)
        nomes   = []
        padroes = [
          /gerente[s]?[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /administrador(?:es)?[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /director(?:es)?[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /(?:designad[oa]s?|nomead[oa]s?)\s+(?:como\s+)?(?:gerente|administrador)[^:]*[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i,
          /presidente[:\s]+([A-ZÀ-Ú][^,;\.]{5,60})/i
        ]
        padroes.each do |padrao|
          texto.scan(padrao).each do |captura|
            nome = captura[0].strip.sub(/\s*,?\s*(?:NIF|NIPC|com|portador|residente).*$/i, "").strip
            nomes << nome if nome.length > 3 && nome.length < 80
          end
        end
        nomes.uniq
      end

      def build_people_entries(names, role_type:, role_label:)
        Array(names).filter_map do |name|
          next if name.blank?

          {
            name: name,
            role_type: role_type,
            role_label: role_label,
            tax_identifier: nil
          }
        end
      end
    end

    class ConsultaEmLote
      def initialize(ficheiro_csv: nil, lista_nipc: [])
        @rc    = RegistoComercial.new(pausa: 3)
        @nipcs = lista_nipc
        carregar_csv(ficheiro_csv) if ficheiro_csv
      end

      def carregar_csv(caminho)
        csv    = CSV.read(caminho, headers: true, encoding: "bom|utf-8")
        coluna = csv.headers.find { |h| h =~ /nipc|nif.*adjudicat/i }
        abort "Não encontrei coluna de NIPC" unless coluna
        @nipcs = csv[coluna].compact.map { |n| n.to_s.strip.gsub(/\D/, "") }
                            .select { |n| n.length == 9 }.uniq
      end

      def executar(ficheiro_saida: "resultados_registo.json")
        resultados = {}
        @nipcs.each_with_index do |nipc, _i|
          begin
            pubs = @rc.pesquisar_por_nipc(nipc)
            next if pubs.empty?
            detalhe = nil
            pubs.first(3).each do |pub|
              next unless pub[:ligacao].is_a?(String)
              detalhe = @rc.obter_detalhe(pub[:ligacao])
              break if detalhe&.any?
            end
            resultados[nipc] = {
              entidade:    pubs.first[:entidade],
              publicacoes: pubs.size,
              socios:      detalhe&.dig(:socios)  || [],
              gerentes:    detalhe&.dig(:gerentes) || [],
              capital:     detalhe&.dig(:capital_social),
              sede:        detalhe&.dig(:sede),
              natureza:    detalhe&.dig(:natureza_juridica)
            }
          rescue StandardError => e
            $stderr.puts "  ✗ #{nipc}: #{e.message}"
          end
        end
        File.write(ficheiro_saida, JSON.pretty_generate(resultados))
        resultados
      end
    end

    class Cruzamento
      def initialize(ficheiro_base:, ficheiro_registo:)
        @contratos = CSV.read(ficheiro_base, headers: true, encoding: "bom|utf-8")
        @registo   = JSON.parse(File.read(ficheiro_registo), symbolize_names: true)
      end

      def detectar_ligacoes
        mapa_pessoas = Hash.new { |h, k| h[k] = [] }
        @registo.each do |nipc, dados|
          ((dados[:socios] || []) + (dados[:gerentes] || [])).uniq.each do |nome|
            mapa_pessoas[normalizar_nome(nome)] << {
              nipc: nipc.to_s, entidade: dados[:entidade],
              papel: dados[:socios]&.include?(nome) ? "sócio" : "gerente"
            }
          end
        end
        mapa_pessoas.select { |_, empresas| empresas.size >= 2 }
                    .map { |nome, empresas| { pessoa: nome, empresas: empresas } }
      end

      private

      def normalizar_nome(nome)
        nome.to_s.strip
            .unicode_normalize(:nfkd)
            .gsub(/[^\x00-\x7F]/, "")
            .downcase.gsub(/\s+/, " ").strip
      end
    end
  end
end
