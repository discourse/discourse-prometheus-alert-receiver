# frozen_string_literal: true

class AlertReceiverAlertSerializer < ApplicationSerializer
  attributes :identifier,
            :status,
            :datacenter,
            :description,
            :starts_at,
            :ends_at,
            :external_url,
            :graph_url,
            :logs_url,
            :grafana_url
end
