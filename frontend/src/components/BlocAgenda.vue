<script setup lang="ts">
import { computed } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { jour, lienGoogleAgenda } from "@/lib/format";

// Livraison estimée + ajout à l'agenda : lien Google Agenda, fichier .ics servi par l'API pour Apple Calendrier
const props = defineProps<{ orderId: string; livraison: string }>();
const { t, locale } = useI18n();

const date = computed(() => jour(props.livraison, locale.value as Langue, { weekday: "long", day: "numeric", month: "long" }));
const google = computed(() => lienGoogleAgenda(props.orderId, props.livraison, t("suivi.agendaTitre"), t("suivi.agendaDetails")));
</script>

<template>
  <div class="agenda">
    <div class="quand">
      {{ t("suivi.livraison") }}<b>{{ date }}</b>
    </div>
    <a :href="google" target="_blank" rel="noopener">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true">
        <rect x="3.5" y="5" width="17" height="15.5" rx="2.5" />
        <path d="M3.5 10h17M8 3v4M16 3v4" /></svg
      >{{ t("suivi.google") }}
    </a>
    <a :href="`/commandes/${encodeURIComponent(orderId)}/agenda`">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true">
        <rect x="3.5" y="5" width="17" height="15.5" rx="2.5" />
        <path d="M3.5 10h17M8 3v4M16 3v4" /></svg
      >{{ t("suivi.apple") }}
    </a>
  </div>
</template>
