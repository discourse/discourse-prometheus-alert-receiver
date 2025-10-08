# frozen_string_literal: true

require "rails_helper"

describe Topic do
  fab!(:topic)
  fab!(:topic_2, :topic)
  fab!(:category) { topic.category }
  fab!(:closed_topic) { Fabricate(:topic, category: category, closed: true) }

  fab!(:plugin_store_row) do
    PluginStore.set(
      ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
      "sometoken",
      { category_id: category.id },
    )
  end

  fab!(:firing_alert) do
    AlertReceiverAlert.create!(
      topic: topic,
      status: "firing",
      identifier: "someidentifier",
      starts_at: Time.zone.now,
      external_url: "someurl",
    )
  end

  fab!(:silenced_alert) do
    AlertReceiverAlert.create!(
      topic: topic,
      status: "silenced",
      identifier: "someidentifier2",
      starts_at: Time.zone.now,
      external_url: "someurl",
    )
  end

  fab!(:suppresed_alert) do
    AlertReceiverAlert.create!(
      topic: topic_2,
      status: "suppressed",
      identifier: "someidentifier2",
      starts_at: Time.zone.now,
      external_url: "someurl",
    )
  end

  fab!(:closed_alert) do
    AlertReceiverAlert.create!(
      topic: closed_topic,
      status: "resolved",
      identifier: "someidentifier",
      starts_at: Time.zone.now,
      external_url: "someurl",
    )
  end

  describe ".firing_alerts" do
    it "should return the right topics" do
      expect(Topic.firing_alerts).to contain_exactly(firing_alert.topic)
    end
  end
end
