# frozen_string_literal: true

module Jobs
  class CreateAlertTopicsIndex < ::Jobs::Base
    ALERT_TOPICS_INDEX_NAME = 'idx_alert_topics'

    def execute(_)
      DB.exec(<<~SQL)
      DROP INDEX IF EXISTS #{ALERT_TOPICS_INDEX_NAME};
      SQL

      if (category_ids = Topic.alerts_category_ids).present?
        DB.exec(<<~SQL)
        CREATE INDEX #{Rails.env.test? ? '' : 'CONCURRENTLY'} #{ALERT_TOPICS_INDEX_NAME}
        ON topics (id) WHERE deleted_at IS NULL AND NOT closed AND category_id IN (#{category_ids.join(",")})
        SQL
      end
    end
  end
end
