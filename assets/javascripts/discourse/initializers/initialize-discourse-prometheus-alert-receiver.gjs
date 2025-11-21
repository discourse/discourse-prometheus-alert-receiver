import Component from "@glimmer/component";
import { withPluginApi } from "discourse/lib/plugin-api";
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
}
