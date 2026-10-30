<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { useI18n } from "vue-i18n";
import { FERMETURE, decompte } from "@/lib/fermeture";

const { t, locale } = useI18n();
const maintenant = ref(new Date());
const reste = computed(() => decompte(maintenant.value));
const date = computed(() => FERMETURE.toLocaleString(locale.value, { dateStyle: "long", timeStyle: "short", timeZone: "Europe/Paris" }));
const deuxChiffres = (n: number) => String(n).padStart(2, "0");
let minuteur: ReturnType<typeof setInterval> | undefined;

onMounted(() => (minuteur = setInterval(() => (maintenant.value = new Date()), 1000)));
onUnmounted(() => clearInterval(minuteur));
</script>

<template>
  <div class="bandeau-fermeture" role="status">
    <template v-if="reste">
      <span>{{ t("fermeture.annonce", { date }) }}</span>
      <span class="minuteur" :aria-label="t('fermeture.reste')">
        <span
          >{{ reste.jours }}<small>{{ t("fermeture.j") }}</small></span
        >
        <span
          >{{ deuxChiffres(reste.heures) }}<small>{{ t("fermeture.h") }}</small></span
        >
        <span
          >{{ deuxChiffres(reste.minutes) }}<small>{{ t("fermeture.min") }}</small></span
        >
        <span
          >{{ deuxChiffres(reste.secondes) }}<small>{{ t("fermeture.s") }}</small></span
        >
      </span>
    </template>
    <span v-else>{{ t("fermeture.ferme") }}</span>
  </div>
</template>

<style scoped>
.bandeau-fermeture {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 6px 14px;
  padding: 8px 16px;
  background: var(--texte);
  color: var(--fond);
  font-size: 0.9rem;
  text-align: center;
}
.minuteur {
  display: inline-flex;
  gap: 8px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.minuteur span {
  padding: 2px 7px;
  border-radius: 6px;
  background: var(--erreur);
  color: #fff;
}
.minuteur small {
  margin-left: 1px;
  font-weight: 500;
  opacity: 0.85;
}
</style>
