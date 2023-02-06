import Component from "@glimmer/component";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";

export default class AlertReceiverTable extends Component {
  @tracked collapsed;

  get isCollapsed() {
    return this.collapsed ?? this.args.defaultCollapsed;
  }

  get showDescriptionColumn() {
    return this.args.alerts.any((a) => a.description);
  }

  @action
  toggleCollapsed() {
    this.collapsed = !this.isCollapsed;
  }
}
