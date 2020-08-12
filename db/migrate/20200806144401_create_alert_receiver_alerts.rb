
# frozen_string_literal: true
class CreateAlertReceiverAlerts < ActiveRecord::Migration[6.0]
  def change
    create_table :alert_receiver_alerts do |t|
      t.integer :topic_id, null: false

      t.string :status, null: false
      t.string :identifier
      t.string :description
      t.string :datacenter

      t.datetime :starts_at, null: false
      t.datetime :ends_at

      t.string :external_url, null: false
      t.string :graph_url
      t.string :logs_url
      t.string :grafana_url
    end

    add_index :alert_receiver_alerts, :topic_id
    add_index :alert_receiver_alerts, [:topic_id, :external_url, :identifier],
                  where: "status in ('firing', 'suppressed')",
                  unique: true,
                  name: :index_alert_receiver_alerts_unique_active

    reversible do |dir|
      dir.up do
        # This migrates existing topic_custom_field data to the new table
        # We only migrate topics which are currently open, or are using prom_alert_history_version=2
        # Older topics used to store the alert data in markdown, so there is no need to migrate the
        # raw data to the new format
        execute <<~SQL
          INSERT INTO alert_receiver_alerts
          (
            topic_id,
            identifier,
            description,
            status,
            datacenter,
            starts_at,
            ends_at,
            external_url,
            graph_url,
            logs_url,
            grafana_url
          )
          SELECT
            tcf.topic_id,
            a.*
          FROM
            topic_custom_fields tcf
          CROSS JOIN LATERAL
            json_to_recordset(tcf.value::json->'alerts') AS
              a(id varchar,
                description varchar,
                status varchar,
                datacenter varchar,

                starts_at timestamp,
                ends_at timestamp,

                external_url varchar,
                graph_url varchar,
                logs_url varchar,
                grafana_url varchar
              )
          JOIN topics on topics.id = tcf.topic_id
          LEFT JOIN topic_custom_fields tcf_version
            ON tcf.topic_id = tcf_version.topic_id
            AND tcf_version.name = 'prom_alert_history_version'
          WHERE tcf.name = 'prom_alert_history'
          AND (tcf_version.value::integer = 2 OR (topics.deleted_at IS NULL AND NOT topics.closed))
          AND json_typeof(tcf.value::json->'alerts') = 'array'
        SQL
      end
    end
  end
end
