# frozen_string_literal: true

require "rails_helper"

RSpec.describe Category do
  let(:category) { Fabricate(:category) }
  let(:admin) { Fabricate(:admin) }

  it "should remove PluginStore fields on destroy" do
    token = "557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983"

    PluginStore.set(
      ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
      token,
      category_id: category.id,
      created_at: Time.zone.now,
      created_by: admin.id,
    )

    category.destroy!

    expect(PluginStore.get(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token)).to eq(nil)
  end
end
