# frozen_string_literal: true

class AlertReceiverAlert < ActiveRecord::Base
  STALE_DURATION = 5.minutes

  belongs_to :topic

  scope :firing, -> { where(status: 'firing') }
  scope :stale, -> { where(status: 'stale') }

  def self.update_resolved_and_suppressed(alerts)
    return [] unless alerts.present?

    value_columns = ['topic_id', 'external_url', 'identifier', 'status', 'ends_at', 'description']

    values_array = alerts.pluck(*value_columns.map(&:to_sym))
    values_hash = Hash[values_array.each_with_index.map { |v, i| [:"value#{i}", v] }]

    values_string = values_hash.keys.map { |key| "(:#{key})" }.join(',')

    query = <<~SQL
      UPDATE alert_receiver_alerts alerts
      SET status=data.status, ends_at=data.ends_at::timestamp, description=data.description
      FROM (values #{values_string})
        AS data(topic_id, external_url, identifier, status, ends_at, description)
      WHERE alerts.topic_id = data.topic_id
        AND alerts.external_url = data.external_url
        AND alerts.identifier = data.identifier
        AND (alerts.status IN ('firing', 'suppressed'))
        AND (
          alerts.status IS DISTINCT FROM data.status
          OR alerts.description IS DISTINCT FROM data.description
        )
      RETURNING alerts.topic_id
    SQL

    topic_ids = DB.query_single(query, values_hash)

    topic_ids.uniq
  end

  def self.update_firing(alerts)
    return [] unless alerts.present?

    insert_columns = column_names - ['id']
    update_columns = insert_columns - ['topic_id', 'identifier', 'starts_at', 'external_url']

    array_to_insert = alerts.pluck(*insert_columns.map(&:to_sym))
    hash_to_insert = Hash[array_to_insert.each_with_index.map { |v, i| [:"value#{i}", v] }]

    insert_columns_string = insert_columns.map { |c| "\"#{c}\"" }.join(',')
    values_string = hash_to_insert.keys.map { |key| "(:#{key})" }.join(',')
    set_string = update_columns.map { |c| "\"#{c}\"=excluded.\"#{c}\"" }.join(',')
    where_string = update_columns.map { |c| "#{table_name}.\"#{c}\" IS DISTINCT FROM excluded.\"#{c}\"" }.join(' OR ')

    query = <<~SQL
      INSERT INTO "#{table_name}" (#{insert_columns_string})
      VALUES #{values_string}
      ON CONFLICT ("topic_id","external_url","identifier")
        WHERE "status" in ('firing', 'suppressed')
      DO UPDATE
        SET #{set_string}
        WHERE #{where_string}
      RETURNING topic_id
    SQL

    topic_ids = DB.query_single query, hash_to_insert

    topic_ids.uniq
  end

  def self.mark_stale(external_url: , active_alerts:)
    value_columns = ['topic_id', 'identifier']

    values_array = active_alerts.pluck(*value_columns.map(&:to_sym))
    values_array << [nil, nil] if values_array.empty?
    values_hash = Hash[values_array.each_with_index.map { |v, i| [:"value#{i}", v] }]

    values_string = values_hash.keys.map { |key| "(:#{key})" }.join(',')

    query = <<~SQL
      WITH active_alerts(topic_id, identifier) AS (
        VALUES #{values_string}
      ),
      stale_alerts AS (
        SELECT id FROM alert_receiver_alerts db_alerts
        WHERE NOT EXISTS (
          SELECT 1 FROM active_alerts
          WHERE db_alerts.topic_id = active_alerts.topic_id::integer
            AND db_alerts.identifier = active_alerts.identifier
        )
        AND db_alerts.external_url = :external_url
        AND db_alerts.status IN ('firing', 'suppressed')
        AND db_alerts.starts_at < :stale_threshold
      )
      UPDATE alert_receiver_alerts alerts
      SET status='stale'
      FROM stale_alerts
      WHERE stale_alerts.id = alerts.id
      RETURNING alerts.topic_id
    SQL

    topic_ids = DB.query_single(
                  query,
                  values_hash.merge(
                    external_url: external_url,
                    stale_threshold: STALE_DURATION.ago
                  )
                )

    topic_ids.uniq
  end

  def self.update_alerts(alerts, mark_stale_external_url: nil)
    alerts = alerts.uniq { |a| [a[:topic_id], a[:external_url], a[:identifier]] }

    groups = alerts.group_by { |a| a[:status] }

    topic_ids = self.update_firing(groups['firing'])
    topic_ids += self.update_resolved_and_suppressed([*groups['resolved'], *groups['suppressed']])

    if mark_stale_external_url
      topic_ids += self.mark_stale(active_alerts: [*groups['firing'], *groups['suppressed']], external_url: mark_stale_external_url)
    end

    topic_ids.uniq
  end
end
