require 'rails_helper'

RSpec.describe DiscoursePrometheusAlertReceiver::ReceiverController do
  let(:category) { Fabricate(:category) }
  let(:assignee_group) { Fabricate(:group) }
  let(:admin) { Fabricate(:admin) }
  let(:response_body) { resp.body }
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

      context "with a category and assignee group" do
        let(:resp) do
          post "/prometheus/receiver/generate.json",
               params: { category_id: category.id, assignee_group_id: assignee_group.id }

          response
        end

        it "succeeds" do
          expect(resp).to be_success
        end

        it "gives us a sensible-looking receiver URL" do
          expect(receiver_url).to match(%r{\A#{Discourse.base_url}/prometheus/receiver/[0-9a-f]{64}\z})
        end

        it "records the category to create topics in" do
          expect(receiver["category_id"]).to eq(category.id)
        end

        it "records the assignee group" do
          expect(receiver["assignee_group_id"]).to eq(assignee_group.id)
        end

        it "preps the data structure" do
          expect(receiver["topic_map"]).to eq({})
        end
      end
    end
  end

  describe "#receive" do
    let(:token) { '557fa3ef557b49451dc9e90e6a7ec1e888937983bee016f5ea52310bd4721983' }
    let(:receiver) { PluginStore.get(::DiscoursePrometheusAlertReceiver::PLUGIN_NAME, token) }

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

    describe "for a valid auto-assigning token" do
      let(:resp) { post "/prometheus/receiver/#{token}", params: payload; response }
      let(:group_key) { "{}/{foo=\"bar\"}:{baz=\"wombat\"}" }
      let!(:assignee) do
        Fabricate(:user).tap { |u| Fabricate(:group_user, user: u, group: assignee_group) }
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
            "version"     => "4",
            "status"      => "firing",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"  => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
                "endsAt"       => "0001-01-01T00:00:00Z",
              },
            ],
          }
        end

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        it "creates a new topic" do
          expect { resp }.to change { Topic.count }.by(1)
        end

        it "sets an appropriate topic title" do
          resp

          expect(topic.title).to eq("Alert investigation required: AnAlert is on the loose")
        end

        it "notes the new topic ID against the group key" do
          resp

          expect(receiver["topic_map"][group_key]).to_not be(nil)
        end

        it "records the alert data on the topic" do
          resp

          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )
        end

        it "sets the first post's body as specified in the alert annotations" do
          resp

          expect(topic).to_not be(nil)
          expect(topic.posts.first.raw).to match(/Test topic\.\.\. test topic\.\.\. whoop whoop/)
        end

        it "includes the alert details in the first post's body" do
          resp

          expect(topic.posts.first.raw).to match(/somethingfunny.*active since 2020-01-02 03:04:05 UTC/)
        end

        it "links the alert IDs to graphs" do
          resp

          expect(topic.posts.first.raw).to match(%r{http://alerts.example.com/graph\?g0.expr=lolrus})
        end

        it "assigns the topic to someone in the assignee group" do
          resp

          expect(topic.assigned_to_user).to_not be(nil)
          expect(topic.assigned_to_user.id).to eq(assignee.id)
        end
      end

      context "an alert with no annotations" do
        let(:topic_map) { {} }

        let(:payload) do
          {
            "version"  => "4",
            "status"   => "firing",
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
            "alerts" => [
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
                "endsAt"       => "0001-01-01T00:00:00Z",
              },
            ],
          }
        end

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        it "creates a new topic" do
          expect { resp }.to change { Topic.count }.by(1)
        end

        it "sets an appropriate topic title" do
          resp

          expect(topic).to_not be(nil)
          expect(topic.title).to eq("Alert investigation required: foo: bar, baz: wombat")
        end

        it "sets the first post's body" do
          resp

          expect(topic).to_not be(nil)
          expect(topic.posts.first.raw).to match(/\A\n\n# Alert History/m)
        end

        it "includes the alert details in the first post's body" do
          resp

          expect(topic.posts.first.raw).to match(/somethingfunny.*active since 2020-01-02 03:04:05 UTC/)
        end

        it "assigns the topic to someone in the assignee group" do
          resp

          expect(topic.assigned_to_user).to_not be(nil)
          expect(topic.assigned_to_user.id).to eq(assignee.id)
        end
      end

      context "a resolving alert on an existing groupKey" do
        before :each do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              }
            ]
          }
          topic.save_custom_fields(true)
        end

        let(:topic_map) { { group_key => topic.id } }

        let(:payload) do
          {
            "version"     => "4",
            "status"      => "resolved",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"  => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "resolved",
                "labels"       => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
                "endsAt"       => "2020-01-02T09:08:07.09876543Z",
              },
            ],
          }
        end

        let(:topic) do
          Fabricate(:topic, posts: [Fabricate(:post)])
        end

        it "updates the existing topic" do
          expect { resp }.to_not change { Topic.count }
        end

        it "records the alert data on the topic" do
          resp

          topic.reload
          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'ends_at'   => "2020-01-02T09:08:07.09876543Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )
        end

        it "includes the alert in the first post's body" do
          resp

          topic.reload
          expect(topic.posts.first.raw).to match(/somethingfunny.*2020-01-02 03:04:05 UTC to 2020-01-02 09:08:07 UTC/)
        end
      end

      context "a new firing alert on an existing groupKey" do
        before :each do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'oldalert',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              }
            ]
          }
          topic.save_custom_fields(true)
        end

        let(:topic_map) { { group_key => topic.id } }

        let(:payload) do
          {
            "version"     => "4",
            "status"      => "firing",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"  => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "oldalert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
              },
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "newalert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-12-31T23:59:59.75645342Z",
              },
            ],
          }
        end

        let(:topic) do
          Fabricate(:topic, posts: [Fabricate(:post)])
        end

        it "updates the existing topic" do
          expect { resp }.to_not change { Topic.count }
        end

        it "records the alert data on the topic" do
          resp

          topic.reload
          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "oldalert",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
              {
                'id' => "newalert",
                'starts_at' => "2020-12-31T23:59:59.75645342Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )
        end

        it "includes the old alert in the first post's body" do
          resp

          topic.reload
          expect(topic.posts.first.raw).to match(/oldalert.*2020-01-02 03:04:05 UTC/)
        end

        it "includes the new alert in the first post's body" do
          resp

          topic.reload
          expect(topic.posts.first.raw).to match(/newalert.*2020-12-31 23:59:59 UTC/)
        end
      end

      context "a repeated alert" do
        before :each do
          topic.custom_fields['prom_alert_history'] = {
            'alerts' => [
              {
                'id' => 'somethingfunny',
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              }
            ]
          }
          topic.save_custom_fields(true)
        end

        let(:topic_map) { { group_key => topic.id } }

        let(:payload) do
          {
            "version"     => "4",
            "status"      => "firing",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"  => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
              },
            ],
          }
        end

        let(:topic) do
          Fabricate(:topic, posts: [Fabricate(:post, raw: 'unchangeable')])
        end

        it "does not change the existing topic" do
          expect { resp }.to_not change { topic.reload; topic.posts.first.revisions.count }
        end

        it "does not change the alert data record" do
          resp

          topic.reload
          expect(topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )
        end

        it "does not change the first post body" do
          resp

          topic.reload
          expect(topic.posts.first.raw).to match(/unchangeable/)
        end
      end

      context "firing alert for a groupkey referencing a closed topic" do
        before :each do
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
            "version"     => "4",
            "status"      => "firing",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"  => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "anotheralert",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-12-31T23:59:59.98765Z",
              },
            ],
          }
        end

        let(:closed_topic) { Fabricate(:topic, closed: true, posts: [Fabricate(:post, raw: "unchanged")]) }
        let(:keyed_topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        it "does not change the closed topic's first post" do
          expect { resp }.to_not change { closed_topic.reload; closed_topic.posts.first.revisions.count }
        end

        it "does not change the closed topic's alert history" do
          resp

          expect(closed_topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "somethingfunny",
                'starts_at' => "2020-01-02T03:04:05.12345678Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )
        end

        it "creates a new topic" do
          expect { resp }.to change { Topic.count }.by(1)
        end

        it "sets an appropriate topic title" do
          resp

          expect(keyed_topic.title).to eq("Alert investigation required: AnAlert is on the loose")
        end

        it "notes the new topic ID against the group key" do
          resp

          expect(receiver["topic_map"][group_key]).to eq(keyed_topic.id)
        end

        it "records the alert data on the new topic" do
          resp

          expect(keyed_topic.custom_fields['prom_alert_history']['alerts']).to eq(
            [
              {
                'id' => "anotheralert",
                'starts_at' => "2020-12-31T23:59:59.98765Z",
                'graph_url' => "http://alerts.example.com/graph?g0.expr=lolrus",
              },
            ]
          )
        end

        it "assigns the new topic to someone in the assignee group" do
          resp

          expect(keyed_topic.assigned_to_user).to_not be(nil)
          expect(keyed_topic.assigned_to_user.id).to eq(assignee.id)
        end

        it "links to the closed topic from the new one" do
          resp

          expect(keyed_topic.posts.first.raw).to match(%r{http://test.localhost/t/#{closed_topic.id}})
        end
      end

      context "resolved alert for a groupkey referencing a closed topic" do
        before :each do
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

        let(:closed_topic) { Fabricate(:topic, closed: true, posts: [Fabricate(:post, raw: "unchanged")]) }
        let(:topic_map) { { group_key => closed_topic.id } }

        let(:payload) do
          {
            "version"     => "4",
            "status"      => "resolved",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"  => "Test topic... test topic... whoop whoop",
              "topic_title" => "Alert investigation required: AnAlert is on the loose",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "resolved",
                "labels"       => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
                "endsAt"       => "2020-01-02T09:08:07.09876543Z",
              },
            ],
          }
        end

        it "does not update the closed topic" do
          expect { resp }.to_not change { closed_topic.posts.first.revisions.count }
        end

        it "does not create a new topic" do
          expect { resp }.to_not change { Topic.count }
        end
      end

      context "firing alert with a designated assignee" do
        let(:topic_map) { {} }

        let(:payload) do
          {
            "version"     => "4",
            "status"      => "firing",
            "groupKey"    => group_key,
            "groupLabels" => {
              "foo" => "bar",
              "baz" => "wombat",
            },
            "commonAnnotations" => {
              "topic_body"     => "Test topic... test topic... whoop whoop",
              "topic_title"    => "Alert investigation required: AnAlert is on the loose",
              "topic_assignee" => "bobtheangryflower",
            },
            "commonLabels" => {
              "alertname" => "AnAlert",
            },
            "alerts" => [
              {
                "status"       => "firing",
                "labels"       => {
                  "id" => "somethingfunny",
                },
                "generatorURL" => "http://alerts.example.com/graph?g0.expr=lolrus",
                "startsAt"     => "2020-01-02T03:04:05.12345678Z",
                "endsAt"       => "0001-01-01T00:00:00Z",
              },
            ],
          }
        end

        let(:topic) do
          Topic.find_by(id: receiver["topic_map"][group_key])
        end

        let!(:bob) { Fabricate(:user, username: "bobtheangryflower") }

        it "creates a new topic" do
          expect { resp }.to change { Topic.count }.by(1)
        end

        it "assigns the topic to the nominated victim" do
          resp

          expect(topic.assigned_to_user).to_not be(nil)
          expect(topic.assigned_to_user.id).to eq(bob.id)
        end
      end
    end
  end
end
