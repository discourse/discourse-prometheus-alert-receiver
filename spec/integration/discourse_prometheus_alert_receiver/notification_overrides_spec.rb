# frozen_string_literal: true
require "rails_helper"

RSpec.describe DiscoursePrometheusAlertReceiver::ReceiverController do
  fab!(:user) { Fabricate(:user) }
  fab!(:alert_category) { Fabricate(:category, slug: "alerts") }
  fab!(:runbook_topic) { Fabricate(:post, user: user).topic }

  def create_topic(user:, category:)
    topic = Fabricate(:topic, category: category, user: user)
    post = Fabricate(:post, topic: topic, user: user, raw: <<~RAW)
      The runbook can be found here: #{runbook_topic.url}
    RAW
    TopicLink.extract_from(post)
    PostAlerter.post_created(post)
  end

  it "prevents link notifications on alert posts" do
    create_topic(user: Discourse.system_user, category: alert_category)
    expect(Notification.count).to eq(0)
  end

  it "doesn't break non-system posts" do
    create_topic(user: Fabricate(:user), category: alert_category)
    expect(Notification.count).to eq(1)
  end

  it "doesn't affect other categories" do
    create_topic(user: Discourse.system_user, category: Fabricate(:category))
    expect(Notification.count).to eq(1)
  end
end
