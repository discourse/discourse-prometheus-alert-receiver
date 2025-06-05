import { on } from "@ember/modifier";
import concatClass from "discourse/helpers/concat-class";
import icon from "discourse/helpers/d-icon";
import ExternalLink from "./external-link";

const CollapseToggle = <template>
  <div
    {{on "click" @toggleCollapsed}}
    class={{concatClass
      "alert-receiver-collapse-toggle"
      (if @collapsed "collapsed")
    }}
    role="button"
  >
    <div class="collapse-icon">
      <a>{{icon (if @collapsed "caret-right" "caret-down")}}</a>
    </div>
    <div class="heading">
      {{@heading}}
      ({{@count}})
    </div>
    <ExternalLink @link={{@headingLink}} />
  </div>
</template>;

export default CollapseToggle;
