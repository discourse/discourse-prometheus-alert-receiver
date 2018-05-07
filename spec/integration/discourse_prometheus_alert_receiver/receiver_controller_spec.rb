require 'rails_helper'

RSpec.describe DiscoursePrometheusAlertReceiver::ReceiverController do
  let(:category) { Fabricate(:category) }
  let(:admin) { Fabricate(:admin) }

  describe "#generate_receiver_url" do
    describe 'as an anonymous user' do
      it "should pretend we don't exist" do
        post "/prometheus/receiver/generate"
        expect(response.status).to eq(404)
      end
    end

    describe 'as a normal user' do
      before do
        sign_in(Fabricate(:user))
      end

      it "should pretend we don't exist" do
        post "/prometheus/receiver/generate"
        expect(response.status).to eq(404)
      end
    end

    describe 'as an admin user' do
      before do
        sign_in(admin)
      end

      describe 'when category_id param is not given' do
        it "should respond with a bad request error" do
          post "/prometheus/receiver/generate.json"
          expect(response.status).to eq(400)
        end
      end

      it 'should be able to generate a receiver url' do
        freeze_time do
          category = Fabricate(:category)

          post "/prometheus/receiver/generate.json", params: { category_id: category.id }

          expect(response).to be_success

          body = JSON.parse(response.body)
          receiver = PluginStoreRow.last

          expect(body['success']).to eq('OK')
          expect(body['url']).to eq("#{Discourse.base_url}/prometheus/receiver/#{receiver.key}")

          expect(receiver.value).to eq({
            category_id: category.id,
            created_at: Time.zone.now,
            created_by: admin.id
          }.to_json)
        end
      end
    end
  end

  describe "#receive" do
    describe 'when token is missing or too short' do
      it "should indicate the resource wasn't found" do
        post "/prometheus/receiver/"
        expect(response.status).to eq(404)

        post "/prometheus/receiver/asdsa"
        expect(response.status).to eq(404)
      end
    end

    describe 'when token is invalid' do
      it "should indicate the request was bad" do
        post "/prometheus/receiver/557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983"
        expect(response.status).to eq(400)
      end
    end

    describe 'for a valid token' do
      let(:token) { '557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983' }
      let(:title) { "Omg some service is down!" }
      let(:raw) { "Server X is on fire!" }

      let(:payload) do
        {
          "commonAnnotations" => {
            "title" => title,
            "raw" => raw
          }
        }
      end

      before do
        SiteSetting.login_required = true

        PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token,
          category_id: category.id,
          created_at: Time.zone.now,
          created_by: admin.id
        )
      end

      describe 'when a new alert is received' do
        it 'should create the right topic' do
          freeze_time(Time.zone.local(2017, 8, 11)) do
            post "/prometheus/receiver/#{token}", params: payload

            expect(response).to be_success

            post = Post.last
            topic = post.topic

            expect(topic.title).to eq("#{title} - 2017-08-11")
            expect(topic.category).to eq(category)
            expect(post.raw).to eq(raw)

            topic_id = PluginStore.get(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
              token
            )[:topic_id]

            expect(topic_id).to eq(topic.id)

            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to_not change { Topic.count }

            expect(response).to be_success

            new_post = Post.last

            expect(new_post.id).to_not eq(post.id)
            expect(post.topic_id).to eq(post.topic_id)
            expect(post.raw).to eq(raw)
          end
        end
      end
    end
  end
end
