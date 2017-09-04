module DiscoursePrometheusAlertReceiver
  class ReceiverController < ApplicationController
    skip_before_action :check_xhr,
                       :verify_authenticity_token,
                       :redirect_to_login_if_required,
                       only: [:receive]

    def generate_receiver_url
      params.require(:category_id)

      category = Category.find_by(id: params[:category_id])
      raise Discourse::InvalidParameters unless category

      token = SecureRandom.hex(32)

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token,
        category_id: category.id,
        created_at: Time.zone.now,
        created_by: current_user.id
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

      topic = Topic.find_by(id: receiver[:topic_id])

      post_attributes =
        if topic
          {
            topic_id: receiver[:topic_id]
          }
        else
          {
            category: category.id,
            title: "#{params["commonAnnotations"]["title"]} - #{Date.today.to_s}"
          }
        end

      post = PostCreator.create!(Discourse.system_user, {
        raw: params["commonAnnotations"]["raw"]
      }.merge(post_attributes))

      receiver[:topic_id] = post.topic_id

      PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
        token, receiver
      )

      render json: success_json
    rescue ActiveRecord::RecordNotSaved => e
      render json: failed_json.merge(error: e.message)
    end
  end
end
