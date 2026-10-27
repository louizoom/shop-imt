<script setup lang="ts">
import { ref, watchEffect } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { appel, ErreurApi } from "@/lib/api";
import { lignesPanier, panier, produits, totalPanier } from "@/lib/boutique";
import { son } from "@/lib/effets";
import { euros, nomProduit } from "@/lib/format";
import { versSuivi } from "@/router";
import { jetonValide, session } from "@/lib/session";

const emit = defineEmits<{ stockChange: [] }>();
const { t, locale } = useI18n();
const email = ref("");
const message = ref("");
const enErreur = ref(false);
const envoi = ref(false);

watchEffect(() => {
  email.value = session.value?.email ?? "";
});

function erreur(texte: string) {
  message.value = texte;
  enErreur.value = true;
}

async function commander() {
  const articles = [...panier].map(([id, quantite]) => ({ id, quantite }));
  const client_email = session.value ? session.value.email : email.value.trim().toLowerCase();
  if (!articles.length) return erreur(t("panier.erreurVide"));
  if (!session.value && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(client_email)) return erreur(t("panier.erreurEmail"));

  envoi.value = true;
  enErreur.value = false;
  message.value = t("panier.envoi");
  try {
    // Connecté : la commande est rattachée au compte (route protégée par le jeton Cognito)
    const connecte = !!(await jetonValide());
    const data = await appel<{ order_id: string }>(connecte ? "/compte/commandes" : "/commandes", {
      corps: { client_email, articles, langue: locale.value },
      jeton: connecte,
    });
    // Le catalogue est mis en cache 5 s par CloudFront : on met le stock à jour localement.
    for (const a of articles) {
      const p = produits.value.find((x) => x.id === a.id);
      if (p) p.stock -= a.quantite;
    }
    panier.clear();
    message.value = "";
    son("commande"); // « tin tinnnn »
    versSuivi(data.order_id);
  } catch (e) {
    son("erreur");
    if (e instanceof ErreurApi && e.statut === 409) {
      erreur(t("panier.erreurStock"));
      emit("stockChange");
    } else if (e instanceof ErreurApi && e.statut < 500 && e.statut !== 401) erreur(e.message);
    else erreur(t("panier.erreurReseau"));
  } finally {
    envoi.value = false;
  }
}
</script>

<template>
  <h2>{{ t("panier.titre") }}</h2>
  <ul class="lignes">
    <li v-for="l in lignesPanier" :key="l.produit.id">
      <span>{{ l.quantite }} × {{ nomProduit(l.produit, locale as Langue) }}</span>
      <span>{{ euros(l.quantite * l.produit.prix, locale as Langue) }}</span>
    </li>
  </ul>
  <p v-if="!lignesPanier.length" class="vide-panier">{{ t("panier.vide") }}</p>
  <div class="total">
    <span>{{ t("panier.total") }}</span
    ><span>{{ euros(totalPanier, locale as Langue) }}</span>
  </div>
  <label for="email">{{ session ? t("panier.emailConnecte") : t("panier.email") }}</label>
  <input id="email" v-model="email" type="email" placeholder="prenom.nom@example.com" autocomplete="email" :readonly="!!session" required />
  <p class="aide">{{ t("panier.aideSes") }}</p>
  <button id="commander" class="principal" :disabled="envoi" @click="commander">{{ t("panier.commander") }}</button>
  <div class="message" :class="{ erreur: enErreur }" aria-live="polite">{{ message }}</div>
</template>
