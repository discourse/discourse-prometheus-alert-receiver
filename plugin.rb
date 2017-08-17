# name: discourse-prometheus-alert-receiver
# about: Receives a Prometheus webhook and creates a topic in Discourse
# version: 0.1

after_initialize do
  [
    '../app/controllers/discourse_prometheus_alert_receiver/receiver_controller.rb',
  ].each { |path| load File.expand_path(path, __FILE__) }

  module ::DiscoursePrometheusAlertReceiver
    PLUGIN_NAME = 'discourse-prometheus-alert-receiver'.freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace ::DiscoursePrometheusAlertReceiver
    end
  end

  self.add_model_callback('Category', :after_destroy) do
    PluginStoreRow
      .where(plugin_name: ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME)
      .where("value::json->>'category_id' = '?'", self.id)
      .destroy_all
  end

  require_dependency "admin_constraint"

  ::DiscoursePrometheusAlertReceiver::Engine.routes.draw do
    post "/receiver/:token" => "receiver#receive", token: /[a-f0-9]{64}/, as: :receive
    post "/receiver/generate" => "receiver#generate_receiver_url", constraints: AdminConstraint.new
  end

  Discourse::Application.routes.append do
    mount ::DiscoursePrometheusAlertReceiver::Engine, at: "/prometheus"
  end
end
