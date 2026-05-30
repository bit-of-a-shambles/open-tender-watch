# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"

module PublicContracts
  module PT
    # Harvests Registo Comercial publications from publicacoes.mj.pt using
    # Ferrum (Chrome DevTools Protocol) + 2Captcha for reCAPTCHA solving.
    #
    # Usage:
    #   harvester = RegistoComercialHarvester.new(captcha_key: ENV["TWOCAPTCHA_KEY"])
    #   harvester.harvest(%w[501412727 500043256])
    #
    # Results are saved incrementally to output_path (default /tmp/rc_results.json).
    # Already-harvested NIFs are skipped, so the process is resumable.
    class RegistoComercialHarvester
      SEARCH_URL = "https://publicacoes.mj.pt/pesquisa.aspx"
      SITEKEY    = "6LfWfwkTAAAAAF_tbbsmS54u0N7kpwdWF_kxp3Ks"

      # Selectors (ContentPlaceHolderMain — updated April 2026)
      GRID_SEL       = "#ctl00_ContentPlaceHolderMain_gvSearchResult"
      DETAIL_SEL     = "#ctl00_ContentPlaceHolderMain_tdTextoPub"
      NIF_INPUT_SEL  = "#ctl00_ContentPlaceHolderMain_txtDadosPubNif"
      SEARCH_BTN_SEL = "#ctl00_ContentPlaceHolderMain_btSearch"
      NO_RESULT_SEL  = "#ctl00_ContentPlaceHolderMain_lbNoResult"

      PEOPLE_ACTS     = /alteraç|designaç|cessaç|constituiç|nomeaç|dissolução|transmissão|fusão/i
      PEOPLE_KEYWORDS = /gerente|sócio|administrador|director|presidente|quota|accionista|titular/i

      POPUP_DELAY_S  = 3
      SEARCH_DELAY_S = 5
      CAPTCHA_POLL_S = 5
      CAPTCHA_POLLS  = 30
      CAPTCHA_JSON_RETRIES = 2

      class CaptchaBalanceError < StandardError; end

      def initialize(captcha_key:, output_path: "/tmp/rc_results.json", headless: false, on_nif_complete: nil)
        @captcha_key    = captcha_key
        @output_path    = output_path
        @headless       = headless
        @on_nif_complete = on_nif_complete
        @results        = load_results
      end

      attr_reader :results

      def harvest(nifs)
        require "ferrum"

        log "2Captcha key: #{@captcha_key[0, 6]}..."
        log "NIFs to process: #{nifs.size}"
        log "2Captcha balance: $#{captcha_balance}"
        log "Existing results: #{@results.size} NIFs"
        log ""

        @browser = Ferrum::Browser.new(
          headless: @headless,
          window_size: [1280, 900],
          timeout: 60,
          browser_options: { "disable-blink-features" => "AutomationControlled" }
        )
        @page = @browser.create_page

        @page.go_to(SEARCH_URL)
        sleep 2

        nifs.each_with_index do |nif, index|
          nif = nif.to_s.strip

          if skip?(nif)
            log "Skipping #{nif} — already have #{@results[nif]['totalResults']} results"
            next
          end

          log "\n#{"═" * 60}"
          log "  NIF #{index + 1}/#{nifs.size}: #{nif}"
          log "═" * 60

          if index > 0
            log "  Waiting #{SEARCH_DELAY_S}s before next search..."
            sleep SEARCH_DELAY_S
          end

          begin
            harvest_nif(nif)
            save_results
            notify_nif_complete(nif)
          rescue CaptchaBalanceError => e
            save_results
            log "  ⚠ Harvest aborted at #{nif}: #{e.message}"
            raise
          rescue => e
            @results[nif] = { "error" => e.message }
            save_results
            log "  ⚠ Harvest failed at #{nif}: #{e.message}"
            next
          end
        end

        print_summary
        log "\nDone. #{@results.size} NIFs in #{@output_path}"
      ensure
        @browser&.quit
      end

      private

      def notify_nif_complete(nif)
        return unless @on_nif_complete
        @on_nif_complete.call(nif, @results[nif])
      rescue => e
        log "  ⚠ on_nif_complete callback error for #{nif}: #{e.message}"
      end

      # ── Search flow ────────────────────────────────────────────────

      def harvest_nif(nif)
        result = do_search(nif)

        case result
        when :no_results
          @results[nif] = { "totalResults" => 0, "rows" => [], "publications" => [] }
          return
        when :failed
          @results[nif] = { "error" => "search_failed" }
          return
        end

        all_rows = []
        publications = []
        page_num = 1

        loop do
          rows = parse_grid_rows
          log "  Page #{page_num}: #{rows.size} results"

          rows.each do |row|
            row["pageNum"] = page_num
            all_rows << row

            next unless row["acto"]&.match?(PEOPLE_ACTS) && row["hasConteudo"]

            log "\n  → #{row['date']} | #{row['acto']&.slice(0, 55)}"
            sleep POPUP_DELAY_S

            pub = fetch_publication_detail(row)
            publications << pub if pub
          end

          break unless has_next_page?
          click_next_page
          page_num += 1
        end

        people_count = publications.count { |p| p["hasPeople"] }
        log "\n  ✓ Total: #{all_rows.size} results, #{publications.size} details, #{people_count} with people"

        @results[nif] = {
          "totalResults" => all_rows.size,
          "rows" => all_rows.map { |r| r.slice("date", "entity", "acto", "concelho") },
          "publications" => publications
        }

        # Navigate back for next NIF
        @page.go_to(SEARCH_URL)
        sleep 2
      end

      def do_search(nif, attempt: 0)
        raise "Too many search retries for #{nif}" if attempt > 3

        unless set_nif_input!(nif)
          log "  ⚠ NIF input field not found — reloading search page and retrying..."
          @page.go_to(SEARCH_URL)
          sleep 2
          return do_search(nif, attempt: attempt + 1)
        end

        solve_nobot
        token = solve_captcha
        inject_captcha_token(token)

        # Click search
        search_btn = @page.at_css(SEARCH_BTN_SEL)
        unless search_btn
          log "  ⚠ Search button not found — reloading search page and retrying..."
          @page.go_to(SEARCH_URL)
          sleep 2
          return do_search(nif, attempt: attempt + 1)
        end

        search_btn.click
        wait_for_load

        # Check result
        return :success if @page.at_css(GRID_SEL)

        no_result_el = @page.at_css(NO_RESULT_SEL)
        if no_result_el
          msg = no_result_el.text
          if msg =~ /Não pode efectuar a pesquisa/i
            log "  ⚠ Rate limited — waiting 30s..."
            sleep 30
            return do_search(nif, attempt: attempt + 1)
          end
          if msg =~ /Validação/i
            log "  ⚠ CAPTCHA validation failed — retrying..."
            @page.go_to(SEARCH_URL)
            sleep 2
            return do_search(nif, attempt: attempt + 1)
          end
          log "  No results: #{msg.strip}"
          return :no_results
        end

        :failed
      end

      # ── CAPTCHA solving ────────────────────────────────────────────

      def solve_captcha
        ensure_captcha_balance!
        log "  📡 Sending CAPTCHA to 2Captcha..."
        submit_url = "https://2captcha.com/in.php?key=#{@captcha_key}" \
                     "&method=userrecaptcha&googlekey=#{SITEKEY}" \
                     "&pageurl=#{CGI.escape(SEARCH_URL)}&json=1"

        resp = fetch_2captcha_json(submit_url, label: "submit")
        raise CaptchaBalanceError, "2Captcha balance is zero; top up and rerun to resume from #{@output_path}" if resp["request"] == "ERROR_ZERO_BALANCE"
        raise "2Captcha submit error: #{resp['request']}" unless resp["status"] == 1

        task_id = resp["request"]
        log "  📡 Task ID: #{task_id} — waiting for solution..."

        CAPTCHA_POLLS.times do |i|
          sleep CAPTCHA_POLL_S
          result_url = "https://2captcha.com/res.php?key=#{@captcha_key}&action=get&id=#{task_id}&json=1"
          result = fetch_2captcha_json(result_url, label: "poll")

          if result["status"] == 1
            log "  ✓ CAPTCHA solved in ~#{(i + 1) * CAPTCHA_POLL_S}s"
            return result["request"]
          end

          raise CaptchaBalanceError, "2Captcha balance is zero; top up and rerun to resume from #{@output_path}" if result["request"] == "ERROR_ZERO_BALANCE"
          raise "2Captcha error: #{result['request']}" unless result["request"] == "CAPCHA_NOT_READY"
          $stdout.write(".")
        end

        balance = captcha_balance
        if zero_balance?(balance)
          raise CaptchaBalanceError, "2Captcha balance is zero; top up and rerun to resume from #{@output_path}"
        end

        raise "2Captcha timeout after #{CAPTCHA_POLLS * CAPTCHA_POLL_S}s"
      end

      def fetch_2captcha_json(url, label:)
        attempts = 0

        begin
          body = http_get(url)
          JSON.parse(body)
        rescue JSON::ParserError
          attempts += 1
          if attempts <= CAPTCHA_JSON_RETRIES
            log "  ⚠ 2Captcha #{label} returned non-JSON; retrying..."
            sleep CAPTCHA_POLL_S
            retry
          end

          raise "2Captcha #{label} returned non-JSON after #{attempts} attempts"
        end
      end

      def inject_captcha_token(token)
        @page.evaluate(<<~JS)
          (() => {
            const textarea = document.getElementById('g-recaptcha-response');
            if (textarea) {
              textarea.style.display = 'block';
              textarea.value = #{token.to_json};
              textarea.style.display = 'none';
            }
            if (typeof ___grecaptcha_cfg !== 'undefined') {
              try {
                const clients = ___grecaptcha_cfg.clients;
                for (const cid in clients) {
                  const client = clients[cid];
                  for (const key in client) {
                    const val = client[key];
                    if (val && typeof val === 'object') {
                      for (const k2 in val) {
                        if (val[k2] && val[k2].callback) val[k2].callback(#{token.to_json});
                      }
                    }
                  }
                }
              } catch {}
            }
          })();
        JS
      end

      def solve_nobot
        @page.evaluate(<<~JS)
          (() => {
            const scripts = document.querySelectorAll('script');
            for (const s of scripts) {
              const match = s.textContent?.match(/ChallengeScript":"eval\\(\\\\u0027(.+?)\\\\u0027\\)/);
              if (match) {
                try {
                  const val = String(eval(match[1]));
                  const el = document.getElementById('ctl00_ContentPlaceHolderMain_NoBot1_NoBot1_NoBotExtender_ClientState');
                  if (el) el.value = val;
                } catch {}
              }
            }
          })();
        JS
      end

      def set_nif_input!(nif)
        @page.evaluate(<<~JS)
          (() => {
            const selectors = [
              '#{NIF_INPUT_SEL}',
              "input[id$='txtDadosPubNif']",
              "input[name$='txtDadosPubNif']"
            ];

            let input = null;
            for (const sel of selectors) {
              input = document.querySelector(sel);
              if (input) break;
            }

            if (!input) return false;

            input.value = '';
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.value = #{nif.to_json};
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            return true;
          })();
        JS
      rescue => e
        log "  ⚠ Failed to set NIF input: #{e.message}"
        false
      end

      # ── Grid parsing ───────────────────────────────────────────────

      def parse_grid_rows
        @page.evaluate(<<~JS)
          (() => {
            const table = document.querySelector('#{GRID_SEL}');
            if (!table) return [];
            const rows = [];
            const trs = table.querySelectorAll('tr');
            for (let i = 1; i < trs.length; i++) {
              const tds = trs[i].querySelectorAll('td');
              if (tds.length < 6) continue;
              if (trs[i].querySelector('table')) continue;
              const link = tds[5]?.querySelector('a');
              rows.push({
                date: tds[0]?.textContent?.trim(),
                nif: tds[1]?.textContent?.trim(),
                entity: tds[2]?.textContent?.trim(),
                concelho: tds[3]?.textContent?.trim(),
                acto: tds[4]?.textContent?.trim(),
                hasConteudo: !!link,
                conteudoHref: link?.href || null,
                rowIndex: i,
              });
            }
            return rows;
          })();
        JS
      end

      def has_next_page?
        @page.evaluate(<<~JS)
          (() => {
            const links = document.querySelectorAll('a');
            for (const a of links) {
              if (a.textContent?.includes('Próximos')) return true;
            }
            return false;
          })();
        JS
      end

      def click_next_page
        @page.evaluate(<<~JS)
          (() => {
            const links = document.querySelectorAll('a');
            for (const a of links) {
              if (a.textContent?.includes('Próximos')) { a.click(); return; }
            }
          })();
        JS
        wait_for_load
      end

      # ── Detail page ────────────────────────────────────────────────

      def fetch_publication_detail(row)
        popup = open_detail_popup(row)
        unless popup
          log "    ✗ No popup opened (link may be inline/PDF)"
          return nil
        end

        detail = popup.evaluate(<<~JS)
          (() => {
            const el = document.querySelector('#{DETAIL_SEL}');
            return {
              html: el ? el.innerHTML : '',
              text: el ? el.textContent : ''
            };
          })();
        JS

        html = detail["html"].to_s
        text = detail["text"].to_s
        if html.empty? && text.empty?
          log "    ✗ No detail content in popup"
          return nil
        end

        has_people = text.match?(PEOPLE_KEYWORDS) || html.match?(PEOPLE_KEYWORDS)

        log "    #{has_people ? '✓ People data found' : '- No people keywords'} (#{text.length} chars)"

        {
          "date"      => row["date"],
          "entity"    => row["entity"],
          "acto"      => row["acto"],
          "concelho"  => row["concelho"],
          "hasPeople" => has_people,
          "html"      => html,
          "text"      => text
        }
      rescue => e
        log "    ✗ Error: #{e.message.slice(0, 100)}"
        nil
      ensure
        popup&.close
      end

      def detail_link_selector(row)
        row_index = row.fetch("rowIndex").to_i
        "#{GRID_SEL} tr:nth-child(#{row_index + 1}) td:nth-child(6) a"
      end

      def open_detail_popup(row)
        href = row["conteudoHref"].to_s

        if href.start_with?("javascript:")
          @page.evaluate(href.delete_prefix("javascript:"))
        else
          selector = detail_link_selector(row)
          @page.at_css(selector)&.click
        end

        60.times do
          popup = @browser.windows.find do |window|
            window != @page && window.current_url.include?("DetalhePublicacao.aspx")
          rescue StandardError
            false
          end
          return popup if popup

          sleep 0.5
        end

        nil
      end

      # ── HTTP helpers ───────────────────────────────────────────────

      def http_get(url)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 15
        http.read_timeout = 30
        response = http.get(uri.request_uri)
        response.body
      end

      def captcha_balance
        http_get("https://2captcha.com/res.php?key=#{@captcha_key}&action=getbalance")
      rescue => e
        "error: #{e.message}"
      end

      def ensure_captcha_balance!
        balance = captcha_balance
        raise CaptchaBalanceError, "2Captcha balance is zero; top up and rerun to resume from #{@output_path}" if zero_balance?(balance)
      end

      def zero_balance?(balance)
        Float(balance).zero?
      rescue ArgumentError, TypeError
        false
      end

      # ── Persistence ────────────────────────────────────────────────

      def load_results
        return {} unless File.exist?(@output_path)
        JSON.parse(File.read(@output_path))
      rescue JSON::ParserError
        {}
      end

      def save_results
        File.write(@output_path, JSON.pretty_generate(@results))
      end

      def skip?(nif)
        return false unless @results.key?(nif)
        return false if @results[nif]["error"]
        @results[nif]["totalResults"]&.positive? || @results[nif]["totalResults"] == 0
      end

      def wait_for_load
        @page.network.wait_for_idle(timeout: 30)
        sleep 2
      rescue Ferrum::TimeoutError
        sleep 2
      end

      def log(msg)
        puts msg
      end

      def print_summary
        log "\n#{"═" * 60}"
        log "  SUMMARY"
        log "═" * 60
        @results.each do |nif, data|
          if data["error"]
            log "  #{nif}: ERROR — #{data['error']}"
          else
            with_people = Array(data["publications"]).count { |p| p["hasPeople"] }
            log "  #{nif}: #{data['totalResults']} results, #{Array(data['publications']).size} details, #{with_people} with people"
          end
        end
      end
    end
  end
end
