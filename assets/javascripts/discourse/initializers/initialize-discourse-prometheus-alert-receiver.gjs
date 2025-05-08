import Component from "@glimmer/component";
import { hbs } from "ember-cli-htmlbars";
import { withSilencedDeprecations } from "discourse/lib/deprecated";
import { withPluginApi } from "discourse/lib/plugin-api";
import { registerWidgetShim } from "discourse/widgets/render-glimmer";
import AlertReceiverData from "../components/alert-receiver/data";

export default {
  name: "discourse-prometheus-alert-receiver",

  initialize() {
    withPluginApi((api) => {
      customizePost(api);
    });
  },
};

function customizePost(api) {
  api.renderAfterWrapperOutlet(
    "post-content-cooked-html",
    class extends Component {
      static shouldRender(args) {
        return args.post.post_number === 1 && args.post?.topic?.alert_data;
      }

      <template>
        <div class="prometheus-alert-receiver">
          <AlertReceiverData @topic={{@outletArgs.post.topic}} />
        </div>
      </template>
    }
  );

  withSilencedDeprecations("discourse.post-stream-widget-overrides", () =>
    customizeWidgetPost(api)
  );
}

function customizeWidgetPost(api) {
  registerWidgetShim(
    "alert-receiver-data",
    "div.prometheus-alert-receiver",
    hbs`<AlertReceiver::Data @topic={{@data.topic}} />`
  );

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
}
