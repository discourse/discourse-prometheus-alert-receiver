import icon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";

const ExternalLink = <template>
  <div class="external-link">
    <a
      target="_blank"
      href={{@link}}
      title={{i18n "prom_alert_receiver.actions.alertmanager"}}
      rel="noopener noreferrer"
    >
      {{icon "far-rectangle-list"}}
    </a>
  </div>
</template>;

export default ExternalLink;
