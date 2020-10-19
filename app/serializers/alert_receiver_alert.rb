# frozen_string_literal: true

class AlertReceiverAlertSerializer < ApplicationSerializer
  attributes :identifier,
            :status,
            :datacenter,
            :description,
            :starts_at,
            :ends_at,
            :external_url,
            :generator_url,
            :link_url,
            :link_text
end
