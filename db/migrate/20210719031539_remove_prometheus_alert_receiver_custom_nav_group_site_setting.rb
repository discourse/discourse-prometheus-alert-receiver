# frozen_string_literal: true

class RemovePrometheusAlertReceiverCustomNavGroupSiteSetting < ActiveRecord::Migration[6.1]
  def up
    execute "DELETE FROM site_settings WHERE name = 'prometheus_alert_receiver_custom_nav_group'"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
