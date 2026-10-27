import { defineConfigWithVueTs, vueTsConfigs } from "@vue/eslint-config-typescript";
import skipFormatting from "@vue/eslint-config-prettier/skip-formatting";
import pluginVue from "eslint-plugin-vue";

// Qualité du code : règles recommandées Vue 3 + TypeScript ; la mise en forme est laissée à Prettier.
export default defineConfigWithVueTs(
  { name: "fichiers", files: ["**/*.{ts,mts,vue}"] },
  { name: "ignores", ignores: ["dist/**", "coverage/**"] },
  pluginVue.configs["flat/recommended"],
  vueTsConfigs.recommended,
  skipFormatting,
  {
    rules: {
      "vue/multi-word-component-names": "off",
    },
  },
);
