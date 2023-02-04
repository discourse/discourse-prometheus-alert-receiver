import { hbs } from "ember-cli-htmlbars";
import { registerWidgetShim } from "discourse/widgets/render-glimmer";

registerWidgetShim(
  "alert-receiver-data",
  "div.prometheus-alert-receiver",
  hbs`<AlertReceiver::Data @alerts={{@data.alerts}} />`
);
