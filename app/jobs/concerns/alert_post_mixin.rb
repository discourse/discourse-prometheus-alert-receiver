# frozen_string_literal: true

module AlertPostMixin
  extend ActiveSupport::Concern

  FIRING_TAG = "firing".freeze
  HIGH_PRIORITY_TAG = "high-priority".freeze
  NEXT_BUSINESS_DAY_SLA = "nbd".freeze

  private

  def local_date(time, starts_at = nil)
    parsed = Time.zone.parse(time)
    format = "L HH:mm"

    if starts_at.present?
      from = Time.zone.parse(starts_at)
      format = "HH:mm" if from.at_beginning_of_day == parsed.at_beginning_of_day
    end

    date = +<<~DATE
    [date=#{parsed.strftime("%Y-%m-%d")} time=#{parsed.strftime("%H:%M:%S")} format="#{format}" displayedTimezone="UTC" timezones="Europe/Paris\\|America/Los_Angeles\\|Asia/Singapore\\|Australia/Sydney"]
    DATE

    date.chomp!
    date
  end

  def get_grafana_dashboard_url(alert, grafana_url)
    return if alert.blank? || grafana_url.blank?

    dashboard_path = alert.dig('annotations', 'grafana_dashboard_path')
    return if dashboard_path.blank?

    "#{grafana_url}#{dashboard_path}"
  end

  def prev_topic_link(topic_id)
    return "" if topic_id.nil?
    created_at = Topic.where(id: topic_id).pluck(:created_at).first
    return "" unless created_at

    "[Previous alert](#{Discourse.base_url}/t/#{topic_id}) #{local_date(created_at.to_s)}\n\n"
  end

  def generate_title(base_title, alert_history)
    firing_count = alert_history&.count { |alert| is_firing?(alert["status"]) }
    if firing_count > 0
      I18n.t("prom_alert_receiver.topic_title.firing", base_title: base_title, count: firing_count)
    else
      I18n.t("prom_alert_receiver.topic_title.not_firing", base_title: base_title)
    end
  end

  def first_post_body(receiver:,
                      topic_body: "",
                      alert_history:,
                      prev_topic_id:)

    output = ""
    output += "#{topic_body}\n\n"
    output += "#{prev_topic_link(prev_topic_id)}\n\n" if prev_topic_id

    output
  end

  def revise_topic(topic:, title:, raw:, datacenters:, firing: nil, high_priority: false)
    post = topic.first_post
    title_changed = topic.title != title
    skip_revision = true

    if post.raw.strip != raw.strip || title_changed || !firing.nil?
      post = topic.first_post

      fields = {
        title: title,
        raw: raw
      }

      fields[:tags] ||= []

      if datacenters.present?
        fields[:tags] = topic.tags.pluck(:name)
        fields[:tags].concat(datacenters)
        fields[:tags].uniq!
      end

      fields[:tags] << HIGH_PRIORITY_TAG.dup if high_priority

      if firing
        fields[:tags] << FIRING_TAG.dup
      else
        fields[:tags].delete(FIRING_TAG)
      end

      PostRevisor.new(post, topic).revise!(
        Discourse.system_user,
        fields,
        skip_revision: skip_revision,
        skip_validations: true,
        validate_topic: true # This is a very weird API
      )
      if firing && title_changed
        topic.update_column(:bumped_at, Time.now)
        TopicTrackingState.publish_latest(topic)
      end
    end
  end

  def is_firing?(status)
    status == "firing".freeze
  end

  def datacenters(alerts)
    alerts.each_with_object(Set.new) do |alert, set|
      set << alert['datacenter'] if alert['datacenter']
    end.to_a
  end
end
