require 'time'
require 'cgi'

module DiscoursePrometheusAlertReceiver
  class ReceiverController < ApplicationController
    skip_before_action :check_xhr,
                       :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       only: [:generate_receiver_url, :receive]

    def generate_receiver_url
      params.require(:category_id)

      category = Category.find_by(id: params[:category_id])
      raise Discourse::InvalidParameters unless category

      receiver_data = {
        category_id: category.id,
        created_at: Time.zone.now,
        created_by: current_user.id
      }

      if params["assignee_group_id"]
        group = Group.find_by(id: params[:assignee_group_id])
        raise Discourse::InvalidParameters unless group

        receiver_data[:assignee_group_id] = group.id
        receiver_data[:topic_map] = {}
      end

      token = SecureRandom.hex(32)

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token,
        receiver_data
      )

      if category.save
        url = "#{Discourse.base_url}/prometheus/receiver/#{token}"

        render json: success_json.merge(url: url)
      else
        render json: failed_json
      end
    end

    def receive
      token = params.require(:token)

      receiver = PluginStore.get(
        ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token
      )

      raise Discourse::InvalidParameters unless receiver

      category = Category.find_by(id: receiver[:category_id])
      raise Discourse::InvalidParameters unless category

      Jobs.enqueue(:process_alert,
        token: token,
        params: params.permit!.to_h
      )

      render json: success_json
    end
  end
end
