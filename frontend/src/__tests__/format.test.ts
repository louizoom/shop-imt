import { describe, expect, it } from "vitest";
import { euros, lienGoogleAgenda, lireEtape, nomProduit } from "@/lib/format";

describe("format", () => {
  it("formate les montants selon la langue", () => {
    expect(euros("69.2", "fr").replace(/\s/g, " ")).toBe("69,20 €");
    expect(euros(69.2, "en")).toBe("€69.20");
  });

  it("lit une étape d'historique avec ou sans détail", () => {
    expect(lireEtape("2026-10-27T10:00:00Z EXPEDIEE | Colissimo")).toEqual({
      date: "2026-10-27T10:00:00Z",
      statut: "EXPEDIEE",
      detail: "Colissimo",
    });
    expect(lireEtape("2026-10-27T10:00:00Z RECUE").detail).toBeUndefined();
  });

  it("choisit le nom traduit par Amazon Translate quand il existe", () => {
    expect(nomProduit({ nom: "Sweat IMT", nom_en: "IMT Sweatshirt" }, "en")).toBe("IMT Sweatshirt");
    expect(nomProduit({ nom: "Sweat IMT" }, "en")).toBe("Sweat IMT");
    expect(nomProduit({ nom: "Sweat IMT", nom_en: "IMT Sweatshirt" }, "fr")).toBe("Sweat IMT");
  });

  it("construit un lien Google Agenda sur la journée de livraison", () => {
    const url = new URL(lienGoogleAgenda("abc", "2026-10-30", "Livraison", "Commande"));
    expect(url.searchParams.get("dates")).toBe("20261030/20261031");
    expect(url.searchParams.get("details")).toBe("Commande abc");
  });
});
