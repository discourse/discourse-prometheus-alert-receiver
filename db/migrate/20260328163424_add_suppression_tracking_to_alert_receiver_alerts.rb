# frozen_string_literal: true

class AddSuppressionTrackingToAlertReceiverAlerts < ActiveRecord::Migration[7.1]
  def change
    add_column :alert_receiver_alerts, :last_suppressed_at, :datetime
  end
end
