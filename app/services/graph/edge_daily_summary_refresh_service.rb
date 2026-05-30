# frozen_string_literal: true

module Graph
  class EdgeDailySummaryRefreshService
    INCREMENTAL_REFRESH_WINDOW_DAYS = 14

    def call
      call_started_at = monotonic_now
      timestamp = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S")
      refresh_start_date = incremental_refresh_start_date
      refresh_mode = refresh_start_date ? "incremental" : "full"
      total_rows_before = GraphEdgeDailySummary.count
      deleted_rows = 0
      delete_ms = 0.0
      insert_ms = 0.0

      GraphEdgeDailySummary.transaction do
        delete_started_at = monotonic_now
        deleted_rows = delete_refresh_window!(refresh_start_date)
        delete_ms = elapsed_ms(delete_started_at)

        insert_started_at = monotonic_now
        ActiveRecord::Base.connection.execute(insert_sql(timestamp, refresh_start_date: refresh_start_date))
        insert_ms = elapsed_ms(insert_started_at)
      end

      Rails.cache.delete(Graph::NetworkMapService::PREAGGREGATED_AVAILABILITY_CACHE_KEY)
      total_rows_after = GraphEdgeDailySummary.count
      inserted_rows = total_rows_after - [ total_rows_before - deleted_rows, 0 ].max

      emit_refresh_telemetry(
        mode: refresh_mode,
        refresh_start_date: refresh_start_date&.iso8601,
        total_rows_before: total_rows_before,
        total_rows_after: total_rows_after,
        deleted_rows: deleted_rows,
        inserted_rows: inserted_rows,
        timings_ms: {
          delete_window: delete_ms,
          insert_window: insert_ms,
          total: elapsed_ms(call_started_at)
        }
      )

      total_rows_after
    end

    private

    def incremental_refresh_start_date
      latest_publication_date = GraphEdgeDailySummary.maximum(:publication_date)
      return nil unless latest_publication_date

      latest_publication_date - INCREMENTAL_REFRESH_WINDOW_DAYS
    end

    def delete_refresh_window!(refresh_start_date)
      scope = GraphEdgeDailySummary.all
      if refresh_start_date
        scope = scope.where("publication_date >= ? OR publication_date IS NULL", refresh_start_date)
      end

      scope.delete_all
    end

    def emit_refresh_telemetry(payload)
      ActiveSupport::Notifications.instrument("graph.edge_summary_refresh", payload)
      Rails.logger.info("graph.edge_summary_refresh #{payload}")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_now - started_at) * 1000.0).round(1)
    end

    def insert_sql(timestamp, refresh_start_date:)
      publication_filter_sql = if refresh_start_date
        cutoff = ActiveRecord::Base.connection.quote(refresh_start_date)
        "AND (contracts.publication_date >= #{cutoff} OR contracts.publication_date IS NULL)"
      else
        ""
      end

      <<~SQL
        INSERT INTO graph_edge_daily_summaries (
          source_entity_id,
          target_entity_id,
          publication_date,
          data_source_id,
          contract_count,
          total_value,
          flagged_contract_count,
          flagged_total_value,
          risk_total_score,
          source_is_public_body,
          source_is_company,
          target_is_public_body,
          target_is_company,
          computed_at,
          created_at,
          updated_at
        )
        SELECT
          contracts.contracting_entity_id,
          contract_winners.entity_id,
          contracts.publication_date,
          contracts.data_source_id,
          COUNT(*),
          COALESCE(SUM(contracts.base_price), 0),
          COALESCE(SUM(CASE WHEN flag_totals.contract_id IS NOT NULL THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN flag_totals.contract_id IS NOT NULL THEN contracts.base_price ELSE 0 END), 0),
          COALESCE(SUM(flag_totals.total_score), 0),
          COALESCE(source_entities.is_public_body, 0),
          COALESCE(source_entities.is_company, 0),
          COALESCE(target_entities.is_public_body, 0),
          COALESCE(target_entities.is_company, 0),
          '#{timestamp}',
          '#{timestamp}',
          '#{timestamp}'
        FROM contracts
        INNER JOIN contract_winners ON contract_winners.contract_id = contracts.id
        INNER JOIN entities source_entities ON source_entities.id = contracts.contracting_entity_id
        INNER JOIN entities target_entities ON target_entities.id = contract_winners.entity_id
        LEFT JOIN (
          SELECT flags.contract_id, SUM(flags.score) AS total_score
          FROM flags
          GROUP BY flags.contract_id
        ) AS flag_totals ON flag_totals.contract_id = contracts.id
        WHERE contracts.contracting_entity_id IS NOT NULL
          AND contract_winners.entity_id IS NOT NULL
          AND contracts.contracting_entity_id != contract_winners.entity_id
          #{publication_filter_sql}
        GROUP BY
          contracts.contracting_entity_id,
          contract_winners.entity_id,
          contracts.publication_date,
          contracts.data_source_id,
          source_entities.is_public_body,
          source_entities.is_company,
          target_entities.is_public_body,
          target_entities.is_company
      SQL
    end
  end
end
