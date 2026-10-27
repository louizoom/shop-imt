import { reactive } from "vue";
import { ErreurApi } from "@/lib/api";

// Ligne d'état partagée par les onglets de la console admin (chargement, erreurs, export)
export const etat = reactive({ texte: "", erreur: false });

export function informer(texte: string, erreur = false) {
  Object.assign(etat, { texte, erreur });
}

type T = (cle: string) => string;

// 401 : session expirée (api.ts a déjà déconnecté) ; 403 : compte hors du groupe Cognito « admins »
export function informerErreur(e: unknown, t: T, defaut: string) {
  if (e instanceof ErreurApi && e.statut === 401) informer(t("admin.sessionExpiree"), true);
  else if (e instanceof ErreurApi && e.statut === 403) informer(t("admin.pasAdmin"), true);
  else informer(e instanceof Error && e.message ? e.message : defaut, true);
}
