# frozen_string_literal: true

# name: discourse-prometheus-alert-receiver
# about: Receives a Prometheus webhook and creates a topic in Discourse
# version: 0.1
# url: https://github.com/discourse/discourse-prometheus-alert-receiver

enabled_site_setting :prometheus_alert_receiver_enabled

register_asset "stylesheets/topic-post.scss"

after_initialize do
  module ::DiscoursePrometheusAlertReceiver
    PLUGIN_NAME = 'discourse-prometheus-alert-receiver'.freeze

    PREVIOUS_TOPIC_CUSTOM_FIELD = 'prom_previous_topic'.freeze
    TOPIC_BODY_CUSTOM_FIELD = 'prom_alert_topic_body'.freeze
    TOPIC_BASE_TITLE_CUSTOM_FIELD = 'prom_alert_topic_base_title'.freeze

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace ::DiscoursePrometheusAlertReceiver
    end
  end

  [
    '../app/controllers/discourse_prometheus_alert_receiver/receiver_controller.rb',
    '../app/models/alert_receiver_alert.rb',
    '../app/serializers/alert_receiver_alert.rb',
    '../app/jobs/concerns/alert_post_mixin.rb',
    '../app/jobs/regular/process_alert.rb',
    '../app/jobs/regular/process_grouped_alerts.rb',
    '../app/jobs/regular/create_alert_topics_index.rb',
  ].each { |path| load File.expand_path(path, __FILE__) }

  unless Rails.env.test?
    %i{
      tagging_enabled
      allow_duplicate_topic_titles
    }.each do |setting|

      unless SiteSetting.public_send(setting)
        SiteSetting.public_send("#{setting}=", true)
      end
    end
  end

  register_topic_custom_field_type(DiscoursePrometheusAlertReceiver::PREVIOUS_TOPIC_CUSTOM_FIELD, :integer)
  register_topic_custom_field_type(DiscoursePrometheusAlertReceiver::TOPIC_BODY_CUSTOM_FIELD, :string)
  register_topic_custom_field_type(DiscoursePrometheusAlertReceiver::TOPIC_BASE_TITLE_CUSTOM_FIELD, :string)

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

  reloadable_patch do
    Topic.has_many :alert_receiver_alerts, dependent: :delete_all
  end

  self.add_model_callback('PluginStoreRow', :after_commit) do
    if self.plugin_name == ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME
      Topic.clear_alerts_category_ids_cache
    end
  end

  add_class_method(:topic, :clear_alerts_category_ids_cache) do
    @alerts_category_ids_cache&.clear
    Jobs.enqueue(:create_alert_topics_index)
  end

  add_class_method(:topic, :alerts_category_ids_cache) do
    @alerts_category_ids_cache ||= DistributedCache.new("alerts_category_ids_cache")

    @alerts_category_ids_cache.defer_get_set("alert_category_ids") do
      alerts_category_ids
    end
  end

  add_class_method(:topic, :alerts_category_ids) do
    PluginStoreRow
      .where(plugin_name: ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME)
      .pluck("value::json->'category_id'")
  end

  add_class_method(:topic, :open_alerts) do
    joins(:alert_receiver_alerts)
      .where("not topics.closed AND topics.category_id IN (?)", alerts_category_ids_cache)
  end

  add_class_method(:topic, :firing_alerts) do |category_ids = []|
    joins(:alert_receiver_alerts)
      .where("alert_receiver_alerts.status": 'firing')
      .where(
        "not topics.closed AND topics.category_id IN (?)",
        category_ids.present? ? category_ids : alerts_category_ids_cache
      )
  end

  add_to_class(:user, :include_alert_counts?) do
    @include_alert_counts ||= begin
      SiteSetting.prometheus_alert_receiver_custom_nav_group.blank? ||
      groups.exists?(name: SiteSetting.prometheus_alert_receiver_custom_nav_group.split("|"))
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

  add_to_serializer(:topic_view, :alert_data) do
    ActiveModel::ArraySerializer.new(object.topic.alert_receiver_alerts)
  end

  add_to_serializer(:topic_view, :include_alert_data?) do
    object.topic.alert_receiver_alerts.present?
  end

  on(:after_extract_linked_users) do |users, post|
    if post.post_number == 1 && post.user == Discourse.system_user && post.topic.category&.slug == 'alerts' # TODO: don't hardcode the category slug
      users.clear
    end
  end

  TopicQuery.add_custom_filter(
    DiscoursePrometheusAlertReceiver::PLUGIN_NAME
  ) do |results, topic_query|

    options = topic_query.options

    if Topic.alerts_category_ids_cache.include?(options[:category_id]) && options[:status] == 'firing'
      results = results.firing_alerts([options[:category_id]])
    end

    results
  end

  require_dependency "admin_constraint"

  ::DiscoursePrometheusAlertReceiver::Engine.routes.draw do
    token_format = /[a-f0-9]{64}/
    post "/receiver/:token" => "receiver#receive", token: token_format, as: :receive
    post "/receiver/resync/:token" => "receiver#receive_grouped_alerts", token: token_format
    post "/receiver/grouped/alerts/:token" => "receiver#receive_grouped_alerts", token: token_format, as: :receive_grouped_alerts
    post "/receiver/generate" => "receiver#generate_receiver_url", constraints: AdminConstraint.new
  end

  Discourse::Application.routes.append do
    mount ::DiscoursePrometheusAlertReceiver::Engine, at: "/prometheus"
  end
end
