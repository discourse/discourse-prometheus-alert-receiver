import { withPluginApi } from "discourse/lib/plugin-api";

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
    });
  }
};
