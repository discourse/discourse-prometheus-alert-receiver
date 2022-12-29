# frozen_string_literal: true

class AddAlertTopicsIndex < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def up
    category_ids = DB.query_single(<<~SQL)
    SELECT
      value::json->'category_id'
    FROM plugin_store_rows
    WHERE plugin_name = 'discourse-prometheus-alert-receiver'
    SQL

    DB.exec(<<~SQL) if category_ids.present?
      CREATE INDEX CONCURRENTLY idx_alert_topics
      ON topics (id)
      WHERE deleted_at IS NULL
      AND NOT closed
      AND category_id IN (#{category_ids.join(",")})
      SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
