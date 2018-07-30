require 'rails_helper'

RSpec.describe DiscoursePrometheusAlertReceiver::ReceiverController do
  let(:category) { Fabricate(:category) }
  let(:assignee_group) { Fabricate(:group) }
  let(:admin) { Fabricate(:admin) }
  let(:response_body) { response.body }
  let(:parsed_response_body) { JSON.parse(response_body) }

  describe "#generate_receiver_url" do
    let(:receiver_url) { parsed_response_body['url'] }
    let(:receiver_token) { parsed_response_body['url'].split('/').last }
    let(:receiver) { PluginStore.get(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, receiver_token) }

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

          expect(response.status).to eq(200)

          body = JSON.parse(response.body)
          receiver = PluginStoreRow.last

          expect(body['success']).to eq('OK')

          expect(body['url']).to eq(
            "#{Discourse.base_url}/prometheus/receiver/#{receiver.key}"
          )

          expect(receiver.value).to eq({
            category_id: category.id,
            created_at: Time.zone.now,
            created_by: admin.id
          }.to_json)
        end
      end

      context "with a category and assignee group" do
        it "should return the right output" do
          post "/prometheus/receiver/generate.json", params: {
            category_id: category.id,
            assignee_group_id: assignee_group.id
          }

          expect(response.status).to eq(200)

          expect(receiver_url).to match(
            %r{\A#{Discourse.base_url}/prometheus/receiver/[0-9a-f]{64}\z}
          )

          expect(receiver["category_id"]).to eq(category.id)
          expect(receiver["assignee_group_id"]).to eq(assignee_group.id)
          expect(receiver["topic_map"]).to eq({})
        end
      end
    end
  end

  describe "#receive" do
    let(:token) do
      '557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983'
    end

    let(:receiver) do
      PluginStore.get(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token)
    end

    before do
      SiteSetting.queue_jobs = false
    end

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
        post "/prometheus/receiver/#{token}"
        expect(response.status).to eq(400)
      end
    end

    describe 'for a valid category-only token' do
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

      it 'should create the right topic' do
        freeze_time(Time.zone.local(2017, 8, 11)) do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { Topic.count }.by(1)

          expect(response.status).to eq(200)

          post = Post.last
          topic = post.topic

          expect(topic.title).to eq("#{title} - 2017-08-11")
          expect(topic.category).to eq(category)
          expect(post.raw).to eq(raw)

          topic_id = PluginStore.get(
            ::DiscoursePrometheusAlertReceiver::PLUGIN_NAME,
            token
          )[:topic_id]

          expect(topic_id).to eq(topic.id)

          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { Topic.count }

          expect(response.status).to eq(200)

          new_post = Post.last

          expect(new_post.id).to_not eq(post.id)
          expect(post.topic_id).to eq(post.topic_id)
          expect(post.raw).to eq(raw)
        end
      end
    end

    describe "for a valid auto-assigning token" do
      let(:group_key) { "{}/{foo=\"bar\"}:{baz=\"wombat\"}" }

      let!(:assignee) do
        Fabricate(:user).tap do |u|
          Fabricate(:group_user, user: u, group: assignee_group)
        end
      end

      before do
        SiteSetting.assign_enabled = true

        PluginStore.set(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token,
          category_id: category.id,
          assignee_group_id: assignee_group.id,
          created_at: Time.zone.now,
          created_by: admin.id,
          topic_map: topic_map,
        )
      end

      context "a firing alert on a previously unseen groupKey" do
        let(:topic_map) { {} }

        let(:payload) do
          {
            "version" => "4",
            "status" => "firing",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "firing",
                "labels" => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
                "endsAt"       => "0001-01-01T00:00:00Z",
              }
            ],
          }
        end

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        it "should create the right topic" do
          messages = MessageBus.track_publish('/alert-receiver') do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to change { Topic.count }.by(1)
          end

          expect(response.status).to eq(200)
          expect(messages.first.data[:firing_alerts_count]).to eq(1)

          expect(topic.category).to eq(category)

          expect(topic.title).to eq(
            ":fire: Alert investigation required: AnAlert is on the loose"
          )

          expect(receiver["topic_map"][group_key]).to eq(topic.id)

          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
            ]
          )

          raw = topic.posts.first.raw

          expect(raw).to include(
            "Test topic\.\.\. test topic\.\.\. whoop whoop"
          )

          expect(raw).to include(
            "[somethingfunny (active since 2020-01-02 03:04:05 UTC)"
          )

          expect(raw).to include(
            "http://alerts.example.com/graph?g0.expr=lolrus"
          )

          expect(topic.assigned_to_user.id).to eq(assignee.id)
        end
      end

      context "an alert with no annotations" do
        let(:topic_map) { {} }

        let(:payload) do
          {
            "version" => "4",
            "status" => "firing",
            "groupKey" => group_key,
            "commonAnnotations" => {
              "unrelated" => "annotation",
            },
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "externalURL" => "supposed.to.be.a.url",
            "alerts" => [
              {
                "status" => "firing",
                "labels" => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-01-02T03:04:05.12345678Z",
                "endsAt" => "0001-01-01T00:00:00Z",
              },
            ],
          }
        end

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        it "should create the right topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { Topic.count }.by(1)

          expect(topic.title).to eq(":fire: alert: foo: bar, baz: wombat")

          raw = topic.posts.first.raw

          expect(raw).to match(/# :fire: Firing Alerts/m)
          expect(raw).to include("supposed.to.be.a.url")

          expect(raw).to include(
            "[somethingfunny (active since 2020-01-02 03:04:05 UTC)]"
          )

          expect(topic.assigned_to_user.id).to eq(assignee.id)
        end
      end

      context "a resolving alert on an existing groupKey" do
        before do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
              {
                'id' => 'somethingnotfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
            ]
          }
          topic.save_custom_fields(true)
        end

        let(:topic_map) { { group_key => topic.id } }

        let(:payload) do
          {
            "version" => "4",
            "status" => "resolved",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "resolved",
                "labels" => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-01-02T03:04:05.12345679Z",
                "endsAt" => "2020-01-02T09:08:07.09876543Z",
              }
            ],
          }
        end

        let(:topic) { Fabricate(:post).topic }

        it "updates the existing topic" do
          messages = MessageBus.track_publish('/alert-receiver') do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to_not change { Topic.count }
          end

          topic.reload

          expect(response.status).to eq(200)
          expect(messages.first.data[:firing_alerts_count]).to eq(1)

          expect(topic.title).to eq(
            "Alert investigation required: AnAlert is on the loose"
          )

          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'ends_at' => "2020-01-02T09:08:07.09876543Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'resolved'
              },
              {
                'id' => 'somethingnotfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              }
            ]
          )

          raw = topic.posts.first.raw

          expect(raw).to include("# :fire: Firing Alerts")

          expect(raw).to include(
            "[somethingnotfunny (active since 2020-01-02 03:04:05 UTC)]"
          )

          expect(raw).to include("# Alert History")

          expect(raw).to include(
            "[somethingfunny (2020-01-02 03:04:05 UTC to 2020-01-02 09:08:07 UTC)]"
          )
        end
      end

      context "a new firing alert on an existing groupKey" do
        before do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'oldalert',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              }
            ]
          }

          topic.save_custom_fields(true)
        end

        let(:topic_map) { { group_key => topic.id } }

        let(:payload) do
          {
            "version" => "4",
            "status" => "firing",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "firing",
                "labels" => {
                  "id" => "oldalert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-01-02T03:04:05.12345678Z",
              },
              {
                "status" => "firing",
                "labels" => {
                  "id" => "newalert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-12-31T23:59:59.75645342Z",
              },
            ],
          }
        end

        let(:topic) { Fabricate(:post).topic }

        it "updates the existing topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { Topic.count }

          topic.reload

          expect(topic.title).to eq(
            ":fire: Alert investigation required: AnAlert is on the loose"
          )

          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "oldalert",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
              {
                'id' => "newalert",
                'starts_at' => "2020-12-31T23:59:59.75645342Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
            ]
          )

          raw = topic.posts.first.raw

          expect(raw).to match(/oldalert.*2020-01-02 03:04:05 UTC/)
          expect(raw).to match(/newalert.*2020-12-31 23:59:59 UTC/)
        end
      end

      context "a repeated alert" do
        before do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              }
            ]
          }

          topic.save_custom_fields(true)

          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { topic.reload; topic.posts.first.revisions.count }.by(1)
        end

        let(:topic_map) { { group_key => topic.id } }

        let(:payload) do
          {
            "version" => "4",
            "status" => "firing",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "firing",
                "labels" => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-01-02T03:04:05.12345678Z",
              },
            ],
          }
        end

        let(:topic) { Fabricate(:post, raw: 'unchangeable').topic }

        it "does not change the existing topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { topic.reload; topic.posts.first.revisions.count }

          topic.reload

          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
            ]
          )
        end
      end

      context "firing alert for a groupkey referencing a closed topic" do
        before do
          closed_topic.update!(
            created_at: DateTime.new(2018, 7, 27, 19, 33, 44)
          )

          closed_topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              }
            ]
          }

          closed_topic.save_custom_fields(true)
        end

        let(:topic_map) { { group_key => closed_topic.id } }

        let(:payload) do
          {
            "version" => "4",
            "status" => "firing",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "firing",
                "labels" => {
                  "id" => "anotheralert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-12-31T23:59:59.98765Z",
              },
            ],
          }
        end

        let(:closed_topic) do
          topic = Fabricate(:post, raw: 'unchanged').topic
          topic.update!(closed: true)
          topic
        end

        let(:keyed_topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        it "does not change the closed topic's first post" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to_not change { closed_topic.reload.posts.first.revisions.count }

          expect(closed_topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )

          expect(keyed_topic.title).to eq(
            ":fire: Alert investigation required: AnAlert is on the loose"
          )

          expect(receiver["topic_map"][group_key]).to eq(keyed_topic.id)

          expect(keyed_topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "anotheralert",
                'starts_at' => "2020-12-31T23:59:59.98765Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => 'firing'
              },
            ]
          )

          expect(keyed_topic.assigned_to_user.id).to eq(assignee.id)

          expect(keyed_topic.posts.first.raw).to include(
            "[Previous alert topic created `2018-07-27 19:33:44 UTC`.](http://test.localhost/t/#{closed_topic.id})"
          )
        end
      end

      context "resolved alert for a groupkey" do
        let(:payload) do
          {
            "version" => "4",
            "status" => "resolved",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "resolved",
                "labels" => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-01-02T03:04:05.12345678Z",
                "endsAt" => "2020-01-02T09:08:07.09876543Z",
              },
            ],
          }
        end

        let(:first_post) { Fabricate(:post, raw: 'unchanged') }
        let(:topic) { first_post.topic }
        let(:topic_map) { { group_key => topic.id } }

        before do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
                'status' => "resolved"
              }
            ]
          }

          topic.save_custom_fields(true)
        end

        describe "referencing an open topic" do
          it "should update the first post of the topic" do
            expect do
              post "/prometheus/receiver/#{token}", params: payload
            end.to change { first_post.revisions.count }.by(1)

            raw = first_post.reload.raw

            expect(raw).to include("# Alert History")

            expect(raw).to include(
              "[somethingfunny (2020-01-02 03:04:05 UTC to 2020-01-02 09:08:07 UTC)]"
            )
          end
        end

        describe "referencing a closed topic" do
          before do
            topic.update!(closed: true)
          end

          it "does not update the closed topic" do
            expect do
              expect do
                post "/prometheus/receiver/#{token}", params: payload
              end.to_not change { first_post.revisions.count }
            end.to_not change { Topic.count }
          end
        end
      end

      context "firing alert with a designated assignee" do
        let(:topic_map) { {} }

        let(:payload) do
          {
            "version" => "4",
            "status" => "firing",
            "groupKey" => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body" => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
              "topic_assignee" => "bobtheangryflower",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status" => "firing",
                "labels" => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt" => "2020-01-02T03:04:05.12345678Z",
                "endsAt" => "0001-01-01T00:00:00Z",
              },
            ],
          }
        end

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        let!(:bob) { Fabricate(:user, username: "bobtheangryflower") }

        it "creates a new topic" do
          expect do
            post "/prometheus/receiver/#{token}", params: payload
          end.to change { Topic.count }.by(1)

          expect(topic.assigned_to_user.id).to eq(bob.id)
        end
      end
    end
  end
end
