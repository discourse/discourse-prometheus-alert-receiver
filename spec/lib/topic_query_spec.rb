# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TopicQuery do
  let(:user) { Fabricate(:user) }
  let(:category) { Fabricate(:category, name: 'alerts') }

  let(:custom_field_key) do
    DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
  end

  describe '#list_latest' do
    it 'should return the right topics' do
      topic1 = Fabricate(:topic, category: category)
      topic2 = Fabricate(:topic, category: category)

      {
        topic1 => 'firing',
        topic2 => 'resolved',
      }.each do |topic, status|
        topic.custom_fields[custom_field_key] = {
          'alerts' => [
            {
              'id' => 'somethingfunny',
              'starts_at' => "2020-01-02T03:04:05.12345678Z",
              'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              'status' => status
            }
          ]
        }

        topic.save_custom_fields(true)
      end

      topic_query = TopicQuery.new(user,
        status: 'firing',
        category: category.slug
      )

      expect(topic_query.list_latest.topics).to eq([topic1])
    end
  end
end
