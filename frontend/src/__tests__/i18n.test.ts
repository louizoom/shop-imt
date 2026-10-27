import { describe, expect, it } from "vitest";
import en from "@/i18n/en";
import fr from "@/i18n/fr";

const cles = (o: object, prefixe = ""): string[] =>
  Object.entries(o).flatMap(([k, v]) => (typeof v === "object" ? cles(v, `${prefixe}${k}.`) : [`${prefixe}${k}`]));

describe("traductions", () => {
  it("FR et EN ont exactement les mêmes clés", () => {
    expect(cles(en).sort()).toEqual(cles(fr).sort());
  });

  it("aucun texte vide ni caractère réservé de vue-i18n", () => {
    for (const messages of [fr, en]) {
      for (const cle of cles(messages)) {
        const texte = cle.split(".").reduce<unknown>((o, k) => (o as Record<string, unknown>)[k], messages) as string;
        expect(texte.trim(), cle).not.toBe("");
        expect(texte, cle).not.toMatch(/[@$]/);
      }
    }
  });
});
