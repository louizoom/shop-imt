import type { Langue } from "@/i18n";

const regions: Record<Langue, string> = { fr: "fr-FR", en: "en-GB" };

export const euros = (montant: number | string, langue: Langue) =>
  Number(montant).toLocaleString(regions[langue], { style: "currency", currency: "EUR" });

export const heure = (iso: string, langue: Langue) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : d.toLocaleTimeString(regions[langue], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
};

export const dateHeure = (iso: string, langue: Langue, style: "short" | "medium" = "medium") =>
  new Date(iso).toLocaleString(regions[langue], { dateStyle: style, timeStyle: "short" });

// Date seule (« 2026-10-30 ») affichée sans décalage de fuseau
export const jour = (iso: string, langue: Langue, options: Intl.DateTimeFormatOptions) =>
  new Date(`${iso}T12:00:00`).toLocaleDateString(regions[langue], options);

export const nomProduit = (p: { nom: string; nom_en?: string | null }, langue: Langue) => (langue === "en" && p.nom_en) || p.nom;

// Entrée d'historique : "<date ISO> <STATUT>" ou "<date ISO> <STATUT> | <détail>"
export function lireEtape(texte: string) {
  const [tete = "", detail] = texte.split(" | ");
  const [date = "", statut = ""] = tete.split(" ");
  return { date, statut, detail };
}

// Lien « ajouter à Google Agenda » pour la journée de livraison
export function lienGoogleAgenda(orderId: string, livraison: string, titre: string, details: string) {
  const debut = new Date(`${livraison}T12:00:00Z`);
  const fin = new Date(debut.getTime() + 86_400_000);
  const ymd = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, "");
  return (
    "https://calendar.google.com/calendar/render?" +
    new URLSearchParams({
      action: "TEMPLATE",
      text: titre,
      dates: `${ymd(debut)}/${ymd(fin)}`,
      details: `${details} ${orderId}`,
    })
  );
}
