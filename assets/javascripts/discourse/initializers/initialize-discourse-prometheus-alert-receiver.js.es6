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
        href: "/c/alerts?status=firing",
        customFilter: category => {
          if (site.get("firing_alerts_count") <= 0) return false;
          return !category || (category && category.get("slug") !== "alerts");
        }
      });

      api.modifyClass("model:nav-item", {
        @computed(
          "name",
          "category",
          "topicTrackingState.messageCount",
          "site.firing_alerts_count"
        )
        count(name, category, _, firingAlertsCount) {
          if (name === "alerts-category") {
            return firingAlertsCount;
          } else {
            return this._super();
          }
        }
      });
    });
  }
};
