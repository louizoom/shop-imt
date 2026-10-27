<script setup lang="ts">
import { computed } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { euros, nomProduit } from "@/lib/format";
import { image, type Produit } from "@/lib/types";

const props = defineProps<{ produit: Produit; quantite: number; ajoute: boolean }>();
const emit = defineEmits<{ changer: [delta: number] }>();
const { t, locale } = useI18n();

const nom = computed(() => nomProduit(props.produit, locale.value as Langue));
const max = computed(() => Math.min(20, props.produit.stock));
</script>

<template>
  <article class="produit" :class="{ choisi: quantite > 0, ajoute }">
    <div class="visuel"><img :src="image(produit.id)" :alt="nom" width="400" height="300" loading="lazy" /></div>
    <div class="infos">
      <span class="nom">{{ nom }}</span>
      <span v-if="produit.stock === 0" class="stock vide">{{ t("boutique.rupture") }}</span>
      <span v-else-if="produit.stock <= 5" class="stock bas">{{ t("boutique.plusQue", { n: produit.stock }) }}</span>
      <span v-else class="stock">{{ t("boutique.enStock", { n: produit.stock }) }}</span>
      <div class="ligne">
        <span class="prix">{{ euros(produit.prix, locale as Langue) }}</span>
        <div class="stepper">
          <button type="button" :aria-label="t('boutique.retirer', { nom })" :disabled="quantite === 0" @click="emit('changer', -1)">
            −
          </button>
          <output>{{ quantite }}</output>
          <button type="button" :aria-label="t('boutique.ajouter', { nom })" :disabled="quantite >= max" @click="emit('changer', 1)">
            +
          </button>
        </div>
      </div>
    </div>
  </article>
</template>
