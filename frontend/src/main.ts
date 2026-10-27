import { createApp } from "vue";
import App from "./App.vue";
import { i18n } from "./i18n";
import { router } from "./router";
import "./styles/base.css";
import "./styles/admin.css";

document.documentElement.lang = i18n.global.locale.value;
createApp(App).use(i18n).use(router).mount("#app");
