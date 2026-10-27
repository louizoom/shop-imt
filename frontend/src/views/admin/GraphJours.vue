<script setup lang="ts">
import { computed } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { euros, jour } from "@/lib/format";
import type { StatsAdmin } from "@/lib/types";

// Histogramme SVG des commandes par jour (survol : nombre et chiffre d'affaires du jour)
const props = defineProps<{ jours: StatsAdmin["par_jour"] }>();
const { t, locale } = useI18n();

const W = 720,
  H = 220,
  G = 34,
  D = 24,
  B = 26,
  HAUT = H - B - 10;

const echelle = computed(() => {
  const max = Math.max(1, ...props.jours.map((j) => j.commandes));
  const pas = Math.ceil(max / 4);
  return { pas, haut: pas * 4 };
});
const graduations = computed(() =>
  [0, 1, 2, 3, 4].map((i) => {
    const v = i * echelle.value.pas;
    return { v, y: 10 + HAUT - (v / echelle.value.haut) * HAUT };
  }),
);
const largeur = computed(() => (W - G - D) / Math.max(1, props.jours.length));
const etiquette = computed(() => Math.ceil(props.jours.length / 8));

const barres = computed(() =>
  props.jours.map((j, i) => {
    const langue = locale.value as Langue;
    const hauteur = (j.commandes / echelle.value.haut) * HAUT;
    const x = G + i * largeur.value + largeur.value * 0.15;
    const date = jour(j.jour, langue, { weekday: "short", day: "numeric", month: "short" });
    return {
      jour: j.jour,
      x,
      y: 10 + HAUT - hauteur,
      l: Math.max(2, largeur.value * 0.7),
      h: Math.max(hauteur, j.commandes ? 2 : 0),
      info: t("admin.infobulle", { date, n: j.commandes, ca: euros(j.chiffre_affaires, langue) }, j.commandes),
      label: (props.jours.length - 1 - i) % etiquette.value === 0 ? jour(j.jour, langue, { day: "numeric", month: "short" }) : "",
    };
  }),
);
</script>

<template>
  <div class="graph">
    <svg :viewBox="`0 0 ${W} ${H}`" role="img" :aria-label="t('admin.parJour')">
      <defs>
        <linearGradient id="degrade-rouge" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#ff3b51" />
          <stop offset="1" stop-color="#6d0614" />
        </linearGradient>
      </defs>
      <g v-for="g in graduations" :key="g.v">
        <line class="grille-ligne" :x1="G" :x2="W - D" :y1="g.y" :y2="g.y" />
        <text class="axe" :x="G - 8" :y="g.y + 4" text-anchor="end">{{ g.v }}</text>
      </g>
      <g v-for="b in barres" :key="b.jour">
        <rect class="barre" :x="b.x" :y="b.y" :width="b.l" :height="b.h" rx="3">
          <title>{{ b.info }}</title>
        </rect>
        <text v-if="b.label" class="axe" :x="b.x + largeur * 0.35" :y="H - 6" text-anchor="middle">{{ b.label }}</text>
      </g>
    </svg>
  </div>
</template>
