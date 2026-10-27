<script setup lang="ts">
import { computed } from "vue";
import { useI18n } from "vue-i18n";

// Barres horizontales : [libellé, valeur, texte affiché]
const props = defineProps<{ lignes: [string, number, string][] }>();
const { t } = useI18n();
const max = computed(() => Math.max(1, ...props.lignes.map((l) => l[1])));
</script>

<template>
  <div class="barres">
    <p v-if="!lignes.length" class="vide">{{ t("admin.vide") }}</p>
    <div v-for="[nom, n, texte] in lignes" :key="nom" class="ligne-barre">
      <span>{{ nom }}</span>
      <div class="piste"><div class="remplie" :style="{ width: `${(n / max) * 100}%` }" /></div>
      <span class="valeur">{{ texte }}</span>
    </div>
  </div>
</template>
