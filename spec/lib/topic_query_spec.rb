# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TopicQuery do
  let(:user) { Fabricate(:user) }
  let(:category) { Fabricate(:category, name: 'alerts') }

  describe '#list_latest' do
    it 'should return the right topics' do
      topic1 = Fabricate(:topic, category: category)
      topic2 = Fabricate(:topic, category: category)

      {
        topic1 => 'firing',
        topic2 => 'resolved',
      }.each do |topic, status|
        topic.alert_receiver_alerts.create!(
          identifier: 'somethingfunny',
          starts_at: "2020-01-02T03:04:05.12345678Z",
          graph_url: "http://graphs.example.com/graph?g0.expr=lolrus",
          external_url: "http://alerts.example.com",
          status: status
        )
      end

      topic_query = TopicQuery.new(user,
        status: 'firing',
        category: category.slug
      )

      expect(topic_query.list_latest.topics).to eq([topic1])
    end
  end
end
