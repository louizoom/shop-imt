<script setup lang="ts">
import { computed, ref } from "vue";
import { useI18n } from "vue-i18n";
import { appel } from "@/lib/api";
import { estAdmin, peutGererStock, peutVoirVentes, roles, session } from "@/lib/session";
import AdminStock from "./admin/AdminStock.vue";
import AdminVentes from "./admin/AdminVentes.vue";
import { etat, informer, informerErreur } from "./admin/message";

// Console de gestion : les onglets dépendent du rôle (groupes Cognito admins, ventes, stock).
// La Lambda admin revérifie le rôle à chaque appel (403).
type Onglet = "ventes" | "stock";
const { t } = useI18n();
const onglets = computed<Onglet[]>(() => [
  ...(peutVoirVentes.value ? ["ventes" as const] : []),
  ...(peutGererStock.value ? ["stock" as const] : []),
]);
const onglet = ref<Onglet>(onglets.value[0] ?? "stock");
const jours = ref(30);
const version = ref(0); // incrémenté par « Actualiser » : les onglets rechargent leurs données

function choisir(nom: Onglet) {
  onglet.value = nom;
  informer("");
}

// Export CSV : la Lambda dépose le fichier dans S3 et renvoie une URL présignée de 5 minutes
async function exporter() {
  informer(t("admin.exportEnCours"));
  try {
    const { url, lignes } = await appel<{ url: string; lignes: number }>(`/admin/export?jours=${jours.value}`, { jeton: true });
    informer(t("admin.exportPret", { n: lignes }, lignes));
    location.href = url;
  } catch (e) {
    informerErreur(e, t, t("admin.majImpossible"));
  }
}
</script>

<template>
  <div class="admin">
    <div class="admin-tete">
      <div>
        <p class="admin-sur">{{ estAdmin ? t("admin.sur") : t("admin.surGestion") }}</p>
        <div class="admin-onglets" role="tablist" :aria-label="t('admin.sections')">
          <button v-for="o in onglets" :key="o" type="button" role="tab" :aria-selected="onglet === o" @click="choisir(o)">
            {{ t(`admin.${o}`) }}
          </button>
        </div>
        <h1>{{ onglet === "stock" ? t("admin.titreStock") : t("admin.titreVentes") }}</h1>
        <p v-if="session" class="aide">
          {{ t("admin.connecte", { email: session.email }) }} ·
          {{ t("admin.role", { role: roles.map((r) => t(`admin.roles.${r}`)).join(", ") }) }}
        </p>
      </div>
      <div class="admin-actions">
        <div v-if="onglet === 'ventes'" class="periodes" role="group" :aria-label="t('admin.periode')">
          <button v-for="n in [7, 30, 90]" :key="n" type="button" :aria-pressed="jours === n" @click="jours = n">
            {{ t("admin.jours", { n }) }}
          </button>
        </div>
        <button v-if="onglet === 'ventes' && estAdmin" type="button" class="admin-bouton" @click="exporter">
          {{ t("admin.exporter") }}
        </button>
        <button type="button" class="admin-bouton" @click="version++">{{ t("admin.actualiser") }}</button>
      </div>
    </div>
    <div class="message" :class="{ erreur: etat.erreur }" aria-live="polite">{{ etat.texte }}</div>
    <AdminStock v-if="onglet === 'stock'" :version="version" />
    <AdminVentes v-else :jours="jours" :version="version" />
  </div>
</template>
