<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { appel } from "@/lib/api";
import { son } from "@/lib/effets";
import { euros, nomProduit } from "@/lib/format";
import { image, type ProduitStock } from "@/lib/types";
import { informer, informerErreur } from "./message";

// Onglet Stock : réassort par +/- (mise à jour atomique DynamoDB côté Lambda, ADD stock :delta)
const props = defineProps<{ version: number }>();
const { t, locale } = useI18n();
const langue = () => locale.value as Langue;

const SEUIL_BAS = 5;
const PAS = [-10, -1, 1, 10];
const produits = ref<ProduitStock[]>([]);
const requetes = new Map<string, number>(); // id -> numéro de la dernière requête (ignore les réponses dans le désordre)

async function charger() {
  informer(t("admin.chargementStock"));
  try {
    produits.value = (await appel<{ produits: ProduitStock[] }>("/admin/stock", { jeton: true })).produits;
    informer("");
  } catch (e) {
    informerErreur(e, t, t("admin.majImpossible"));
  }
}

const kpis = computed(() => {
  const liste = produits.value;
  const bas = liste.filter((p) => p.stock > 0 && p.stock <= SEUIL_BAS).length;
  const ruptures = liste.filter((p) => p.stock === 0).length;
  return [
    { titre: t("admin.enStock"), valeur: String(liste.reduce((s, p) => s + p.stock, 0)) },
    {
      titre: t("admin.valeur"),
      valeur: euros(
        liste.reduce((s, p) => s + p.stock * Number(p.prix), 0),
        langue(),
      ),
    },
    { titre: t("admin.stocksBas"), valeur: String(bas), chaud: bas > 0 },
    { titre: t("admin.ruptures"), valeur: String(ruptures), chaud: ruptures > 0 },
  ];
});

function niveau(stock: number) {
  if (stock === 0) return { classe: "rupture", libelle: t("admin.niveauRupture") };
  if (stock <= SEUIL_BAS) return { classe: "bas", libelle: t("admin.niveauBas") };
  return { classe: "", libelle: t("admin.niveauOk") };
}

async function ajuster(p: ProduitStock, delta: number) {
  const numero = (requetes.get(p.id) ?? 0) + 1;
  requetes.set(p.id, numero);
  p.stock += delta; // affichage immédiat, corrigé par la réponse de l'API
  son(delta > 0 ? "ajout" : "retrait");
  try {
    const r = await appel<{ stock: number }>("/admin/stock", { jeton: true, corps: { id: p.id, delta } });
    if (requetes.get(p.id) === numero) p.stock = r.stock;
    informer("");
  } catch (e) {
    p.stock -= delta;
    son("erreur");
    informerErreur(e, t, t("admin.majImpossible"));
  }
}

const libelle = (delta: number) => (delta > 0 ? `+${delta}` : `−${-delta}`);

watch(() => props.version, charger, { immediate: true });
</script>

<template>
  <div id="admin-stock">
    <div class="kpis">
      <div v-for="k in kpis" :key="k.titre" class="kpi" :class="{ chaud: k.chaud }">
        <span>{{ k.titre }}</span
        ><strong>{{ k.valeur }}</strong>
      </div>
    </div>
    <section class="admin-carte">
      <h2>{{ t("admin.reassort") }}</h2>
      <div class="stock-liste">
        <div v-for="p in produits" :key="p.id" class="stock-ligne">
          <img :src="image(p.id)" alt="" />
          <div>
            <div class="nom">{{ nomProduit(p, langue()) }}</div>
            <div class="prix">{{ euros(p.prix, langue()) }} · {{ p.id }}</div>
          </div>
          <span class="niveau" :class="niveau(p.stock).classe">{{ niveau(p.stock).libelle }}</span>
          <div class="reglage">
            <template v-for="(delta, i) in PAS" :key="delta">
              <output v-if="i === 2" :aria-label="t('admin.stockDe', { nom: nomProduit(p, langue()) })">{{ p.stock }}</output>
              <button
                type="button"
                :disabled="p.stock + delta < 0 || p.stock + delta > 999"
                :aria-label="t(delta > 0 ? 'admin.ajouterN' : 'admin.retirerN', { n: Math.abs(delta), nom: nomProduit(p, langue()) })"
                @click="ajuster(p, delta)"
              >
                {{ libelle(delta) }}
              </button>
            </template>
          </div>
        </div>
      </div>
    </section>
  </div>
</template>
