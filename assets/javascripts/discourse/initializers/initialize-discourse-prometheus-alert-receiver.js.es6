import { withPluginApi } from "discourse/lib/plugin-api";
import computed from "ember-addons/ember-computed-decorators";

export default {
  name: "discourse-prometheus-alert-receiver",

  initialize() {
    withPluginApi("0.8.9", api => {
      const messageBus = api.container.lookup("message-bus:main");
      if (!messageBus) {
        return;
      }

      const site = api.container.lookup("site:main");

      messageBus.subscribe("/alert-receiver", payload => {
        site.set("firing_alerts_count", payload.firing_alerts_count);
      });

      api.addNavigationBarItem({
        name: "alerts-category",
        site,
        href: "/c/alerts?status=open",
        customFilter: category => {
          let alertCount = site.get("open_alerts_count") || 0;
          if (alertCount <= 0) return false;
          return !category;
        }
      });

      api.modifyClass("model:nav-item", {
        @computed(
          "name",
          "category",
          "topicTrackingState.messageCount",
          "site.open_alerts_count"
        )
        count(name, category, _, openAlertsCount) {
          if (name === "alerts-category") {
            return openAlertsCount;
          } else {
            return this._super();
          }
        }
      });
    });
  }
};
