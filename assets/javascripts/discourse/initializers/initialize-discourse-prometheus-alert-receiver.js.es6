import { withPluginApi } from "discourse/lib/plugin-api";
import { observes } from "discourse-common/utils/decorators";

export default {
  name: "discourse-prometheus-alert-receiver",

  initialize() {
    withPluginApi("0.8.9", (api) => {
      const messageBus = api.container.lookup("message-bus:main");
      if (!messageBus) {
        return;
      }

      const site = api.container.lookup("site:main");

      messageBus.subscribe("/alert-receiver", (payload) => {
        site.set("firing_alerts_count", payload.firing_alerts_count);
      });

      api.decorateWidget("post-contents:after-cooked", (dec) => {
        if (dec.attrs.post_number === 1) {
          const postModel = dec.getModel();
          if (postModel && postModel.topic.alert_data) {
            return dec.attach("alert-receiver-data", {
              alerts: postModel.topic.alert_data,
            });
          }
        }
      });

      api.modifyClass("controller:topic", {
        pluginId: "discourse-prometheus-alert-receiver",
        @observes("model.alert_data")
        _alertDataChanged() {
          if (this.model && this.model.alert_data && this.model.postStream) {
            this.appEvents.trigger("post-stream:refresh", {
              id: this.model.postStream.firstPostId,
            });
          }
        },

        _quoteAlert(text) {
          this.quoteState.selected(this.model.postStream.firstPostId, text, {});
          this.send("selectText");
        },

        init() {
          this._super(...arguments);
          this.appEvents.on("alerts:quote-alert", this, "_quoteAlert");
        },

        willDestroy() {
          this._super(...arguments);
          this.appEvents.off("alerts:quote-alert", this, "_quoteAlert");
        },
      });
    });
  },
};
