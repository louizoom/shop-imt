// Fin du projet : le site ferme à cette date, puis le workflow GitHub « Autodestruction » supprime toute
// l'infrastructure AWS. La même date est écrite dans .github/workflows/autodestruction.yml.
export const FERMETURE = new Date("2026-11-13T14:00:00Z");

export interface Decompte {
  jours: number;
  heures: number;
  minutes: number;
  secondes: number;
}

// Temps restant avant la fermeture, null une fois la date passée
export function decompte(maintenant: Date = new Date()): Decompte | null {
  const reste = Math.floor((FERMETURE.getTime() - maintenant.getTime()) / 1000);
  if (reste <= 0) return null;
  return {
    jours: Math.floor(reste / 86400),
    heures: Math.floor((reste % 86400) / 3600),
    minutes: Math.floor((reste % 3600) / 60),
    secondes: reste % 60,
  };
}
