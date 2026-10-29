<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from "vue";
import { useI18n } from "vue-i18n";
import FicheSuivi from "@/components/FicheSuivi.vue";
import { versSuivi } from "@/router";
import type { Commande } from "@/lib/types";

const props = withDefaults(defineProps<{ commande?: string }>(), { commande: "" });
const { t } = useI18n();
const saisie = ref(props.commande);
const fiche = ref<Commande | null>(null);
const message = ref("");
let suiviEnCours = 0; // jeton pour arrêter un suivi quand on en démarre un autre
const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Suivi en direct : la page interroge l'API toutes les 2 s (~4 min au maximum) jusqu'à la livraison
async function suivre(orderId: string) {
  const jeton = ++suiviEnCours;
  fiche.value = null;
  message.value = t("suivi.recherche");
  for (let i = 0; i < 120 && jeton === suiviEnCours; i++) {
    try {
      const r = await fetch(`/commandes/${encodeURIComponent(orderId)}`);
      const c = await r.json();
      if (jeton !== suiviEnCours) return;
      if (!r.ok) {
        message.value = r.status === 404 ? t("suivi.introuvable") : t("suivi.invalide");
        return;
      }
      message.value = "";
      fiche.value = c as Commande;
      if (c.statut === "LIVREE") return;
    } catch {
      if (i === 0) message.value = t("suivi.reessai");
    }
    await pause(2000);
  }
}

watch(
  () => props.commande,
  (id) => {
    saisie.value = id;
    if (id) suivre(id);
    else {
      suiviEnCours++;
      fiche.value = null;
      message.value = "";
    }
  },
  { immediate: true },
);
onBeforeUnmount(() => {
  suiviEnCours++;
});

function soumettre() {
  const brut = saisie.value.trim();
  const id = /^shop-/i.test(brut) ? brut.toUpperCase() : brut; // SHOP-000042-K7QF, même tapé en minuscules
  if (id) versSuivi(id);
}
</script>

<template>
  <div class="suivi">
    <form class="recherche" @submit.prevent="soumettre">
      <input v-model="saisie" type="text" :placeholder="t('suivi.placeholder')" :aria-label="t('suivi.numero')" :autofocus="!commande" />
      <button>{{ t("suivi.bouton") }}</button>
    </form>
    <FicheSuivi v-if="fiche" :commande="fiche" />
    <div v-else-if="message" class="fiche" aria-live="polite">{{ message }}</div>
  </div>
</template>
