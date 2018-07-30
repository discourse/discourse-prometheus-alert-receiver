# name: discourse-prometheus-alert-receiver
# about: Receives a Prometheus webhook and creates a topic in Discourse
# version: 0.1
# url: https://github.com/discourse/discourse-prometheus-alert-receiver

after_initialize do
  [
    '../app/controllers/discourse_prometheus_alert_receiver/receiver_controller.rb',
    '../app/jobs/regular/process_alert.rb',
  ].each { |path| load File.expand_path(path, __FILE__) }

  module ::DiscoursePrometheusAlertReceiver
    PLUGIN_NAME = 'discourse-prometheus-alert-receiver'.freeze

    ALERT_HISTORY_CUSTOM_FIELD  = 'prom_alert_history'.freeze
    PREVIOUS_TOPIC_CUSTOM_FIELD = 'prom_previous_topic'.freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace ::DiscoursePrometheusAlertReceiver
    end
  end

  register_topic_custom_field_type(DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD, :json)
  register_topic_custom_field_type(DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD, :integer)

  self.add_model_callback('Category', :after_destroy) do
    PluginStoreRow
      .where(plugin_name: ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME)
      .where("value::json->>'category_id' = '?'", self.id)
      .destroy_all
  end

  self.add_model_callback('Group', :after_destroy) do
    PluginStoreRow
      .where(plugin_name: ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME)
      .where("value::json->>'assignee_group_id' = '?'", self.id)
      .destroy_all
  end

  add_class_method(:topic, :firing_alerts) do
    joins(:_custom_fields)
      .where("
        topic_custom_fields.value LIKE '%\"status\":\"firing\"%'
        AND topic_custom_fields.name = ?
      ", DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD)
  end

  add_to_serializer(:site, :firing_alerts_count) do
    Topic.firing_alerts.count
  end

  add_to_serializer(:site, :include_firing_alerts_count?) do
    scope.user
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
