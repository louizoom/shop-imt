import { computed, reactive, ref } from "vue";
import type { Produit } from "./types";

// État partagé de la boutique : catalogue et panier (id -> quantité)
export const produits = ref<Produit[]>([]);
export const panier = reactive(new Map<string, number>());

export const lignesPanier = computed(() =>
  [...panier].flatMap(([id, quantite]) => {
    const produit = produits.value.find((p) => p.id === id);
    return produit ? [{ produit, quantite }] : [];
  }),
);
export const nbArticles = computed(() => lignesPanier.value.reduce((s, l) => s + l.quantite, 0));
export const totalPanier = computed(() => lignesPanier.value.reduce((s, l) => s + l.quantite * l.produit.prix, 0));

export function changerQuantite(id: string, delta: number) {
  const q = Math.max(0, (panier.get(id) ?? 0) + delta);
  if (q) panier.set(id, q);
  else panier.delete(id);
}
