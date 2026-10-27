<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { appel } from "@/lib/api";
import { dateHeure, euros } from "@/lib/format";
import { versSuivi } from "@/router";
import type { CommandeAdmin, StatsAdmin } from "@/lib/types";
import BarresAdmin from "./BarresAdmin.vue";
import GraphJours from "./GraphJours.vue";
import { informer, informerErreur } from "./message";

// Onglet Ventes : statistiques et commandes calculées par la Lambda admin (DynamoDB, index par date)
const props = defineProps<{ jours: number; version: number }>();
const { t, locale } = useI18n();
const langue = () => locale.value as Langue;

const stats = ref<StatsAdmin | null>(null);
const commandes = ref<CommandeAdmin[]>([]);
const recherche = ref("");
const visibles = ref(25); // « Afficher plus » en ajoute 25

async function charger() {
  informer(t("admin.chargement"));
  try {
    const [s, liste] = await Promise.all([
      appel<StatsAdmin>(`/admin/stats?jours=${props.jours}`, { jeton: true }),
      appel<{ commandes: CommandeAdmin[] }>(`/admin/commandes?jours=${props.jours}`, { jeton: true }),
    ]);
    stats.value = s;
    commandes.value = liste.commandes;
    visibles.value = 25;
    informer("");
  } catch (e) {
    informerErreur(e, t, t("admin.majImpossible"));
  }
}

const kpis = computed(() => {
  const s = stats.value;
  if (!s) return [];
  const n = s.periode_jours;
  return [
    { titre: t("admin.aujourdhui"), valeur: String(s.commandes_aujourdhui), chaud: true },
    { titre: t("admin.septJours"), valeur: String(s.commandes_7_jours) },
    { titre: t("admin.commandesPeriode", { n }), valeur: String(s.commandes) },
    { titre: t("admin.caPeriode", { n }), valeur: euros(s.chiffre_affaires, langue()), chaud: true },
    { titre: t("admin.panierMoyen"), valeur: euros(s.panier_moyen, langue()) },
    { titre: t("admin.clients"), valeur: String(s.clients_uniques) },
  ];
});

const lignesStatuts = computed<[string, number, string][]>(() =>
  Object.entries(stats.value?.statuts ?? {}).map(([s, n]) => [t(`statuts.${s}`), n ?? 0, String(n)]),
);
const lignesProduits = computed<[string, number, string][]>(() =>
  (stats.value?.produits ?? []).slice(0, 6).map((p) => [p.nom, p.quantite, `${p.quantite} · ${euros(p.chiffre_affaires, langue())}`]),
);

const filtrees = computed(() => {
  const filtre = recherche.value.trim().toLowerCase();
  return commandes.value.filter((c) => c.client_email.includes(filtre));
});

const classeEtat = (s: string) => (s === "LIVREE" ? "etat ok" : s === "INCIDENT_TRANSPORT" ? "etat alerte" : "etat");

watch(recherche, () => {
  visibles.value = 25;
});
watch(() => [props.jours, props.version], charger, { immediate: true });
</script>

<template>
  <div id="admin-ventes">
    <div class="kpis">
      <div v-for="k in kpis" :key="k.titre" class="kpi" :class="{ chaud: k.chaud }">
        <span>{{ k.titre }}</span
        ><strong>{{ k.valeur }}</strong>
      </div>
    </div>
    <div v-if="stats" class="admin-grille">
      <section class="admin-carte large">
        <h2>{{ t("admin.parJour") }}</h2>
        <GraphJours :jours="stats.par_jour" />
      </section>
      <section class="admin-carte">
        <h2>{{ t("admin.statuts") }}</h2>
        <BarresAdmin :lignes="lignesStatuts" />
      </section>
      <section class="admin-carte">
        <h2>{{ t("admin.meilleures") }}</h2>
        <BarresAdmin :lignes="lignesProduits" />
      </section>
    </div>
    <section class="admin-carte">
      <div class="entete-tableau">
        <h2>
          {{ t("admin.commandes") }} <span>({{ filtrees.length }})</span>
        </h2>
        <input
          id="admin-recherche"
          v-model="recherche"
          type="search"
          :placeholder="t('admin.rechercher')"
          :aria-label="t('admin.rechercher')"
        />
      </div>
      <div class="table-admin">
        <table>
          <thead>
            <tr>
              <th>{{ t("admin.date") }}</th>
              <th>{{ t("admin.client") }}</th>
              <th>{{ t("admin.articles") }}</th>
              <th>{{ t("admin.total") }}</th>
              <th>{{ t("admin.statut") }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-if="!filtrees.length">
              <td class="vide" colspan="5">{{ t("admin.aucune") }}</td>
            </tr>
            <tr v-for="c in filtrees.slice(0, visibles)" :key="c.order_id" :title="t('admin.ouvrir')" @click="versSuivi(c.order_id)">
              <td>{{ dateHeure(c.cree_le, langue(), "short") }}</td>
              <td class="client">
                {{ c.client_email }}<span v-if="c.compte" class="compte-badge">{{ t("admin.badgeCompte") }}</span>
              </td>
              <td>{{ c.nb_articles }}</td>
              <td class="montant">{{ euros(c.total, langue()) }}</td>
              <td>
                <span :class="classeEtat(c.statut)">{{ t(`statuts.${c.statut}`) }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <button v-if="filtrees.length > visibles" type="button" class="admin-bouton plus" @click="visibles += 25">
        {{ t("admin.plus") }}
      </button>
    </section>
  </div>
</template>
