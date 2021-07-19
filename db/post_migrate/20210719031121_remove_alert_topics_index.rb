# frozen_string_literal: true

class RemoveAlertTopicsIndex < ActiveRecord::Migration[6.1]
  def up
    DB.exec(<<~SQL)
    DROP INDEX IF EXISTS idx_alert_topics
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
