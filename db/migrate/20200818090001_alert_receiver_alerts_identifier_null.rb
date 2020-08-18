
# frozen_string_literal: true
class AlertReceiverAlertsIdentifierNull < ActiveRecord::Migration[6.0]
  def change
    # Remove duplicates
    execute <<~SQL
      DELETE FROM alert_receiver_alerts a1
      USING (
        SELECT MAX(id) as id, external_url, topic_id, identifier
        FROM alert_receiver_alerts
        GROUP BY (external_url, topic_id, identifier)
        HAVING COUNT(*) > 1
      ) a2
      WHERE
        a1.identifier IS NULL AND
        a1.topic_id = a2.topic_id AND
        a1.external_url = a2.external_url AND
        a1.id <> a2.id
    SQL

    execute <<~SQL
      UPDATE alert_receiver_alerts
      SET identifier = ''
      WHERE identifier IS NULL
    SQL

    change_column_null :alert_receiver_alerts, :identifier, false
  end
end
