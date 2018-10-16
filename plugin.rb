# name: discourse-prometheus-alert-receiver
# about: Receives a Prometheus webhook and creates a topic in Discourse
# version: 0.1
# url: https://github.com/discourse/discourse-prometheus-alert-receiver

enabled_site_setting :prometheus_alert_receiver_enabled

register_asset "stylesheets/topic-post.scss"

after_initialize do
  [
    '../app/controllers/discourse_prometheus_alert_receiver/receiver_controller.rb',
    '../app/jobs/concerns/alert_post_mixin.rb',
    '../app/jobs/regular/process_alert.rb',
    '../app/jobs/regular/process_grouped_alerts.rb',
    '../lib/opsgenie_schedule.rb'
  ].each { |path| load File.expand_path(path, __FILE__) }

  module ::DiscoursePrometheusAlertReceiver
    PLUGIN_NAME = 'discourse-prometheus-alert-receiver'.freeze

    ALERT_HISTORY_CUSTOM_FIELD  = 'prom_alert_history'.freeze
    PREVIOUS_TOPIC_CUSTOM_FIELD = 'prom_previous_topic'.freeze
    TOPIC_BODY_CUSTOM_FIELD = 'prom_alert_topic_body'.freeze
    TOPIC_TITLE_CUSTOM_FIELD = 'prom_alert_topic_title'.freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace ::DiscoursePrometheusAlertReceiver
    end
  end

  %i{
    tagging_enabled
    allow_duplicate_topic_titles
  }.each do |setting|

    unless SiteSetting.public_send(setting)
      SiteSetting.public_send("#{setting}=", true)
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

  add_class_method(:topic, :open_alerts) do
    joins(:_custom_fields)
      .where("topic_custom_fields.name = ?",
        DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD
      )
      .where("not closed")

  end

  add_class_method(:topic, :firing_alerts) do
    joins(:_custom_fields)
      .where("
        topic_custom_fields.value LIKE '%\"status\":\"firing\"%'
        AND topic_custom_fields.name = ?
      ", DiscoursePrometheusAlertReceiver::ALERT_HISTORY_CUSTOM_FIELD)
  end

  add_to_class(:user, :include_alert_counts?) do
    @include_alert_counts ||= begin
      SiteSetting.prometheus_alert_receiver_custom_nav_group.blank? ||
      groups.exists?(name: SiteSetting.prometheus_alert_receiver_custom_nav_group)
    end
  end

  add_to_serializer(:site, :firing_alerts_count) do
    Topic.firing_alerts.count
  end

  add_to_serializer(:site, :open_alerts_count) do
    Topic.open_alerts.count
  end

  add_to_serializer(:site, :include_open_alerts_count?) do
    scope.user&.include_alert_counts?
  end

  add_to_serializer(:site, :include_firing_alerts_count?) do
    scope.user&.include_alert_counts?
  end

  TopicQuery.add_custom_filter(
    DiscoursePrometheusAlertReceiver::PLUGIN_NAME
  ) do |results, topic_query|

    options = topic_query.options
    category_id = Category.where(slug: 'alerts').pluck(:id).first

    if options[:category_id] == category_id && options[:status] == 'firing'
      results = results.firing_alerts
    end

    results
  end

  require_dependency "admin_constraint"

  ::DiscoursePrometheusAlertReceiver::Engine.routes.draw do
    token_format = /[a-f0-9]{64}/
    post "/receiver/:token" => "receiver#receive", token: token_format, as: :receive
    post "/receiver/grouped/alerts/:token" => "receiver#receive_grouped_alerts", token: token_format, as: :receive_grouped_alerts
    post "/receiver/generate" => "receiver#generate_receiver_url", constraints: AdminConstraint.new
  end

  Discourse::Application.routes.append do
    mount ::DiscoursePrometheusAlertReceiver::Engine, at: "/prometheus"
  end
end
