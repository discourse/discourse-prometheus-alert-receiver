Captures Prometheus Alertmanager events into Discourse, and creates a topic
for every group of alerts currently firing. It will continue to keep track
of all alerts in the group in the same topic until the topic is closed
(indicating that the "incident" is over). Future alerts for the same group
will then create a new topic, linking to the previous one.

In addition, all newly created topics will be assigned to a
randomly-selected member of a specified group.

# Setup

1.  Install this plugin in [the usual
    fashion](https://meta.discourse.org/t/install-a-plugin/19157) into your
    Discourse site. You will also need to install the [discourse-assign
    plugin](https://github.com/discourse/discourse-assign), which this plugin
    depends on.

1.  The plugin makes extensive use of tags and creates multiple topics with the
    same name. As such, `SiteSetting.allow_duplicate_topic_titles` and
    `SiteSetting.tagging_enabled` will be enabled by the plugin upon installation.

1.  Create a new receiver URL by POSTing (as an admin user, so probably using
    an API key) to `/prometheus/receiver/generate`, with a request body that
    includes `category_id` (the numeric ID of the site category to create all
    new topics in) and `assignee_group_id` (the numeric group ID of the group
    from which to select an initial assignee). Take note of the URL in the
    response body, you will need that to configure the Prometheus
    Alertmanager.

1.  Configure the Alertmanager to send webhook requests to your receiver URL,
    with a config something like this:

         receivers:
           - name: discourse
             webhook_configs:
               - send_resolved: true
                 url: 'https://discourse.example.com/prometheus/receiver/asdf1234<etc>'

    You can set a reasonable `repeat_interval` if you like, as the alert
    receiver will deal gracefully with repeated alerts.

1.  For all alerts you send to Discourse, you can provide some annotations
    in the alert rule to customise the created topic. However, Prometheus
    templates are limited in what they can do, so there's a certain amount of
    hard-coding in the title.

    The recognised annotations are:

- **`topic_title`** -- the title to give to all newly-created topics for
  the alert. If you don't set this, you'll get a fairly gnarly-looking
  topic title.

- **`topic_body`** -- the opening paragraph(s) of the first post in all
  newly-created topics for the alert, in markdown format. It is useful
  to give a brief description of the problem, and potentially links to a
  runbook or other useful information.

- **`topic_assignee`**: This overrides the random group member selection,
  and allows you to "force-assign" alerts to one person. The intended
  use-case for this is during the development phase of a new alert, to
  prevent spurious false-positives from annoying everyone. The forced
  assignee does not need to be a member of the group that assignees are
  normally chosen from.

- **`group_topic_assignee`**: Given the `Group#id` or `Group#name` for a group,
  this overrides the `assignee_group_id` that was created with the receiver
  token. A person in the group will be randomly selected for assignment to the
  alert.

- **`description`** -- the description will be displayed under each alert.

## TODO

1. Admin UI to generate a receiver URL for Prometheus Alertmanager webhook.
