<script setup lang="ts">
import { nextTick, onMounted, ref } from "vue";
import { useI18n } from "vue-i18n";
import CarteProduit from "@/components/CarteProduit.vue";
import PanierCommande from "@/components/PanierCommande.vue";
import { changerQuantite, nbArticles, panier, produits, totalPanier } from "@/lib/boutique";
import { rebond, son } from "@/lib/effets";
import { euros } from "@/lib/format";
import type { Langue } from "@/i18n";
import type { Produit } from "@/lib/types";

const { t, locale } = useI18n();
const erreur = ref(false);
const dernierAjout = ref<string | null>(null);
const panneau = ref<HTMLElement | null>(null);
const panneauVisible = ref(false);

async function chargerCatalogue() {
  try {
    const r = await fetch("/produits");
    if (!r.ok) throw new Error(String(r.status));
    produits.value = (await r.json()) as Produit[];
    erreur.value = false;
  } catch {
    erreur.value = true;
  }
}

async function changer(id: string, delta: number) {
  changerQuantite(id, delta);
  dernierAjout.value = delta > 0 ? id : null;
  son(delta > 0 ? "ajout" : "retrait");
  if (delta > 0) {
    await nextTick();
    rebond(document.getElementById("nb-articles"));
    rebond(document.querySelector(".barre-panier"));
  }
  setTimeout(() => {
    if (dernierAjout.value === id) dernierAjout.value = null;
  }, 450);
}

// Sur téléphone, le panier est sous le catalogue : une barre flottante y amène, tant qu'il n'est pas à l'écran.
onMounted(() => {
  chargerCatalogue();
  if (panneau.value && "IntersectionObserver" in window) {
    new IntersectionObserver(([e]) => {
      panneauVisible.value = !!e?.isIntersecting;
    }).observe(panneau.value);
  }
});
</script>

<template>
  <div>
    <div class="hero">
      <h1>{{ t("boutique.titre") }}</h1>
      <p>{{ t("boutique.sousTitre") }}</p>
    </div>
    <div class="boutique">
      <div class="grille" aria-live="polite">
        <template v-if="produits.length">
          <CarteProduit
            v-for="p in produits"
            :key="p.id"
            :produit="p"
            :quantite="panier.get(p.id) ?? 0"
            :ajoute="dernierAjout === p.id"
            @changer="changer(p.id, $event)"
          />
        </template>
        <template v-else>{{ erreur ? t("boutique.erreurCatalogue") : t("boutique.chargement") }}</template>
      </div>
      <button
        v-show="panier.size > 0 && !panneauVisible"
        type="button"
        class="barre-panier"
        @click="panneau?.scrollIntoView({ behavior: 'smooth', block: 'start' })"
      >
        <span>{{ t("panier.resume", { n: nbArticles }, nbArticles) }} · {{ euros(totalPanier, locale as Langue) }}</span
        ><span>{{ t("panier.voir") }}</span>
      </button>
      <aside ref="panneau" class="panneau"><PanierCommande @stock-change="chargerCatalogue" /></aside>
    </div>
  </div>
</template>
