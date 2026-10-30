import { describe, expect, it } from "vitest";
import { FERMETURE, decompte } from "@/lib/fermeture";

describe("fermeture", () => {
  it("décompose le temps restant", () => {
    const avant = new Date(FERMETURE.getTime() - ((2 * 24 + 3) * 3600 + 4 * 60 + 5) * 1000);
    expect(decompte(avant)).toEqual({ jours: 2, heures: 3, minutes: 4, secondes: 5 });
  });

  it("renvoie null une fois la date passée", () => {
    expect(decompte(FERMETURE)).toBeNull();
    expect(decompte(new Date(FERMETURE.getTime() + 1000))).toBeNull();
  });
});
