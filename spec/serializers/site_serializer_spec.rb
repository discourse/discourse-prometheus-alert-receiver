# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteSerializer do
  describe '#firing_alerts' do
    let(:json) do
      site = Site.new(guardian)
      SiteSerializer.new(site, root: false, scope: guardian).as_json
    end

    before do
      topic1 = Fabricate(:post).topic
      topic2 = Fabricate(:post).topic
      topic3 = Fabricate(:post).topic
      topic4 = Fabricate(:post).topic
      topic4.trash!

      {
        topic1 => 'firing',
        topic2 => 'resolved',
        topic3 => 'firing'
      }.each do |topic, status|
        topic.alert_receiver_alerts.create!(
              identifier: 'somethingfunny',
              starts_at: "2020-01-02T03:04:05.12345678Z",
              generator_url: "http://alerts.example.com/graph?g0.expr=lolrus",
              status: status,
              external_url: "alerts.example.com"
        )
      end
    end

    describe 'for an anon user' do
      let(:guardian) { Guardian.new }

      it 'should not include firing_alerts' do
        expect(json[:firing_alerts_count]).to eq(nil)
      end
    end

    describe 'for a logged in user' do
      let(:guardian) { Guardian.new(Fabricate(:user)) }

      it 'should include the right count' do
        expect(json[:firing_alerts_count]).to eq(2)
        expect(json[:open_alerts_count]).to eq(3)
      end
    end
  end
end
