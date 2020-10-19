# frozen_string_literal: true

class AlertReceiverAlertsAddLinkColumns < ActiveRecord::Migration[6.0]
  def change
    add_column :alert_receiver_alerts, :link_url, :string
    add_column :alert_receiver_alerts, :link_text, :string

    execute <<~SQL
      UPDATE alert_receiver_alerts
      SET link_url = COALESCE(grafana_url, logs_url)
    SQL

    # graph_url is confusing, because 'graph' can be synonymous with 'grafana'
    # Renaming the graph_url column to 'generator_url', which matches alertmanager terminology
    add_column :alert_receiver_alerts, :generator_url, :string

    execute <<~SQL
      UPDATE alert_receiver_alerts
      SET generator_url = graph_url
    SQL
  end
end
