import { jetonValide, deconnecter } from "./session";

// L'API est servie par CloudFront sur le même domaine que le site (/produits, /commandes, /compte, /admin).

export class ErreurApi extends Error {
  constructor(
    message: string,
    public statut: number,
  ) {
    super(message);
  }
}

export async function appel<T>(chemin: string, options: { corps?: unknown; jeton?: boolean } = {}): Promise<T> {
  const headers: Record<string, string> = {};
  if (options.jeton) {
    const jeton = await jetonValide();
    if (!jeton) throw new ErreurApi("session", 401);
    headers.Authorization = `Bearer ${jeton}`;
  }
  const init: RequestInit = { headers };
  if (options.corps !== undefined) {
    headers["Content-Type"] = "application/json";
    Object.assign(init, { method: "POST", body: JSON.stringify(options.corps) });
  }
  const r = await fetch(chemin, init);
  const data = await r.json().catch(() => ({}));
  if (r.status === 401 && options.jeton) deconnecter();
  if (!r.ok) throw new ErreurApi((data as { erreur?: string }).erreur ?? `Erreur ${r.status}`, r.status);
  return data as T;
}
