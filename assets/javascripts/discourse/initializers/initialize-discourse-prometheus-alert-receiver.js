import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discourse-prometheus-alert-receiver",

  initialize() {
    withPluginApi("0.8.9", (api) => {
      api.decorateWidget("post-contents:after-cooked", (dec) => {
        if (dec.attrs.post_number === 1) {
          const postModel = dec.getModel();
          if (postModel?.topic?.alert_data) {
            return dec.attach("alert-receiver-data", {
              topic: postModel.topic,
            });
          }
        }
      });
    });
  },
};
