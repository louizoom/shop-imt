// Formes des réponses de l'API (Lambdas Python derrière API Gateway et CloudFront)

export interface Produit {
  id: string;
  nom: string;
  nom_en?: string;
  prix: number;
  stock: number;
}

export interface LigneCommande {
  id: string;
  nom: string;
  nom_en?: string;
  quantite: number;
  prix_unitaire: string;
}

export type Statut = "RECUE" | "EN_PREPARATION" | "EMBALLEE" | "EXPEDIEE" | "INCIDENT_TRANSPORT" | "EN_LIVRAISON" | "LIVREE";

export interface Commande {
  order_id: string;
  statut: Statut;
  total: string;
  articles: LigneCommande[];
  historique: string[];
  transporteur?: string | null;
  numero_suivi?: string | null;
  cree_le: string;
  livraison_estimee?: string | null;
}

export interface CommandeHistorique {
  order_id: string;
  statut: Statut;
  total: string;
  cree_le: string;
  nb_articles: number;
  transporteur?: string | null;
  articles: LigneCommande[];
}

export interface StatsAdmin {
  periode_jours: number;
  commandes: number;
  commandes_aujourdhui: number;
  commandes_7_jours: number;
  chiffre_affaires: string;
  panier_moyen: string;
  clients_uniques: number;
  par_jour: { jour: string; commandes: number; chiffre_affaires: string }[];
  statuts: Partial<Record<Statut, number>>;
  produits: { nom: string; quantite: number; chiffre_affaires: string }[];
}

export interface CommandeAdmin {
  order_id: string;
  cree_le: string;
  client_email: string;
  compte: boolean;
  statut: Statut;
  total: string;
  nb_articles: number;
}

export interface ProduitStock {
  id: string;
  nom: string;
  nom_en?: string | null;
  prix: string;
  stock: number;
}

export const JALONS: Statut[] = ["RECUE", "EN_PREPARATION", "EXPEDIEE", "EN_LIVRAISON", "LIVREE"];
export const IMAGES = new Set(["p001", "p002", "p003", "p004", "p005", "p006"]);
export const image = (id: string) => (IMAGES.has(id) ? `/img/${id}.jpg` : "/img/logo.svg");
