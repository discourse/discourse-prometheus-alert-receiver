import Component from "@glimmer/component";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { service } from "@ember/service";
import { applyLocalDates } from "discourse/lib/local-dates";

export default class AlertReceiverDate extends Component {
  @service siteSettings;

  @action
  applyLocalDates(element) {
    applyLocalDates([element], this.siteSettings);
  }

  <template>
    <span
      class="alert-receiver-date discourse-local-date"
      data-format={{if @hideDate "HH:mm" "YYYY-MM-DD HH:mm"}}
      data-date={{@date}}
      data-time={{@time}}
      data-timezone="UTC"
      data-displayed-timezone="UTC"
      {{didInsert this.applyLocalDates}}
    >{{@date}}T{{@time}}</span>
  </template>
}
