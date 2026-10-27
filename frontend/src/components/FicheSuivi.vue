<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { useI18n } from "vue-i18n";
import BlocAgenda from "@/components/BlocAgenda.vue";
import type { Langue } from "@/i18n";
import { confettis, son } from "@/lib/effets";
import { euros, heure, lireEtape, nomProduit } from "@/lib/format";
import { JALONS, type Commande, type Statut } from "@/lib/types";

const props = defineProps<{ commande: Commande }>();
const { t, locale } = useI18n();
const lang = computed(() => locale.value as Langue);

const etapes = computed(() => props.commande.historique.map(lireEtape));
const livree = computed(() => props.commande.statut === "LIVREE");
const incident = computed(() => props.commande.statut === "INCIDENT_TRANSPORT");
const atteint = computed(() => Math.max(...etapes.value.map((e) => JALONS.indexOf(e.statut as Statut))));
const pct = ref(0); // part de l'ancienne valeur pour animer la barre
const nouvelles = ref(0); // étapes arrivées depuis le dernier rafraîchissement
const etatChange = ref(false);
const celebration = ref(false);
const libelle = (s: string) => (t(`statuts.${s}`) !== `statuts.${s}` ? t(`statuts.${s}`) : s);

const CLE_FETES = "shopimt-livraisons-fetees";
function feter(orderId: string) {
  let fetes: string[] = [];
  try {
    fetes = JSON.parse(localStorage.getItem(CLE_FETES) ?? "[]");
  } catch {
    /* rien */
  }
  if (fetes.includes(orderId)) return;
  try {
    localStorage.setItem(CLE_FETES, JSON.stringify([...fetes, orderId].slice(-50)));
  } catch {
    /* navigation privée */
  }
  celebration.value = true;
  son("livree");
  confettis();
}

// Sons et fête : seulement quand le statut change sous les yeux du client (ou première visite d'un colis livré)
watch(
  () => props.commande,
  async (c, avant) => {
    const meme = avant?.order_id === c.order_id;
    nouvelles.value = meme ? c.historique.length - avant!.historique.length : 0;
    etatChange.value = meme && avant!.statut !== c.statut;
    if (!meme) celebration.value = false;
    const arrivees = c.historique.slice(-Math.max(nouvelles.value, 0) || c.historique.length).map((e) => lireEtape(e).statut);
    if (meme && nouvelles.value > 0) {
      if (c.statut !== "LIVREE" && arrivees.includes("EXPEDIEE")) son("expediee");
      else if (c.statut === "INCIDENT_TRANSPORT" && arrivees.includes("INCIDENT_TRANSPORT")) son("erreur");
    }
    if (c.statut === "LIVREE" && avant?.statut !== "LIVREE") feter(c.order_id);
    await nextTick();
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        pct.value = (atteint.value / (JALONS.length - 1)) * 100;
      }),
    );
  },
  { immediate: true },
);
</script>

<template>
  <div id="fiche" class="fiche" :class="{ celebration }" aria-live="polite">
    <div class="entete">
      <div>
        <h2>{{ livree ? t("suivi.arrive") : t("suivi.titre") }}</h2>
        <code>{{ commande.order_id }}</code>
      </div>
      <span :key="commande.statut" class="etat" :class="{ ok: livree, alerte: incident, change: etatChange }">{{
        libelle(commande.statut)
      }}</span>
    </div>

    <div class="colis">
      <span
        >{{ t("suivi.passee") }} : <b>{{ heure(commande.cree_le, lang) }}</b></span
      >
      <span v-if="commande.transporteur"
        >{{ t("suivi.transporteur") }} : <b>{{ commande.transporteur }}</b></span
      >
      <span v-if="commande.numero_suivi && etapes.some((e) => e.statut === 'EXPEDIEE')"
        >{{ t("suivi.numeroSuivi") }} : <b>{{ commande.numero_suivi }}</b></span
      >
    </div>
    <BlocAgenda v-if="commande.livraison_estimee && !livree" :order-id="commande.order_id" :livraison="commande.livraison_estimee" />

    <div class="progression" :class="{ ok: livree }"><div :style="{ width: `${pct}%` }" /></div>
    <div class="jalons">
      <span v-for="(j, i) in JALONS" :key="j" :class="{ fait: i <= atteint }">{{ libelle(j) }}</span>
    </div>

    <ol class="timeline">
      <li
        v-for="(e, i) in [...etapes].reverse()"
        :key="`${e.date}-${e.statut}`"
        :class="{
          incident: e.statut === 'INCIDENT_TRANSPORT',
          courant: i === 0 && !livree && e.statut !== 'INCIDENT_TRANSPORT',
          nouveau: i < nouvelles,
        }"
      >
        <time>{{ heure(e.date, lang) }}</time>
        <div class="titre">{{ libelle(e.statut) }}</div>
        <div v-if="e.detail" class="detail">{{ e.detail }}</div>
      </li>
    </ol>

    <div class="recap">
      <ul class="lignes">
        <li v-for="a in commande.articles" :key="a.id">
          <span>{{ a.quantite }} × {{ nomProduit(a, lang) }}</span
          ><span>{{ euros(a.quantite * Number(a.prix_unitaire), lang) }}</span>
        </li>
      </ul>
      <div class="total">
        <span>{{ t("suivi.total") }}</span
        ><span>{{ euros(commande.total, lang) }}</span>
      </div>
    </div>
  </div>
</template>
