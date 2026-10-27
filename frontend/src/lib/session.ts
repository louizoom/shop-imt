import { computed, ref } from "vue";

// Comptes clients : Amazon Cognito appelé directement depuis le navigateur (API publique, pas de secret).
// config.json est publié par Terraform à côté du site : { region, cognitoClient }.

export interface Session {
  email: string;
  idToken: string;
  refreshToken: string;
  expire: number;
}
interface Config {
  region: string;
  cognitoClient: string;
}
export class ErreurCognito extends Error {
  constructor(
    message: string,
    public code: string,
  ) {
    super(message);
  }
}

const CLE = "shopimt-session";
let config: Config | null = null;
export const comptesActifs = ref(true); // false si config.json est absent : boutique sans comptes
export const session = ref<Session | null>(lire());

function lire(): Session | null {
  try {
    return JSON.parse(localStorage.getItem(CLE) ?? "null");
  } catch {
    return null;
  }
}

export function lireJeton(jwt: string): Record<string, unknown> {
  const b64 = (jwt.split(".")[1] ?? "").replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(decodeURIComponent(escape(atob(b64))));
}

// Le jeton d'identité liste les groupes Cognito du compte ; l'API revérifie de toute façon (403).
export const estAdmin = computed(() => {
  if (!session.value) return false;
  const groupes = lireJeton(session.value.idToken)["cognito:groups"];
  return Array.isArray(groupes) && groupes.includes("admins");
});

export async function chargerConfig() {
  try {
    const r = await fetch("/config.json", { cache: "no-store" });
    if (!r.ok) throw new Error(String(r.status));
    config = await r.json();
  } catch {
    comptesActifs.value = false;
  }
}

export async function cognito<T = Record<string, unknown>>(action: string, corps: Record<string, unknown>): Promise<T> {
  if (!config) throw new ErreurCognito("Cognito indisponible", "Indisponible");
  const r = await fetch(`https://cognito-idp.${config.region}.amazonaws.com/`, {
    method: "POST",
    headers: { "Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": `AWSCognitoIdentityProviderService.${action}` },
    body: JSON.stringify({ ClientId: config.cognitoClient, ...corps }),
  });
  const data = await r.json();
  if (!r.ok)
    throw new ErreurCognito(
      data.message ?? "Erreur",
      String(data.__type ?? "")
        .split("#")
        .pop() ?? "",
    );
  return data as T;
}

interface Authentification {
  AuthenticationResult: { IdToken: string; RefreshToken?: string };
}

function enregistrer(res: Authentification["AuthenticationResult"], refresh: string) {
  const infos = lireJeton(res.IdToken) as { email: string; exp: number };
  session.value = { email: infos.email, idToken: res.IdToken, refreshToken: refresh, expire: infos.exp * 1000 };
  try {
    localStorage.setItem(CLE, JSON.stringify(session.value));
  } catch {
    /* navigation privée */
  }
}

export async function connecter(email: string, motDePasse: string) {
  const res = await cognito<Authentification>("InitiateAuth", {
    AuthFlow: "USER_PASSWORD_AUTH",
    AuthParameters: { USERNAME: email, PASSWORD: motDePasse },
  });
  enregistrer(res.AuthenticationResult, res.AuthenticationResult.RefreshToken ?? "");
}

export function deconnecter() {
  session.value = null;
  try {
    localStorage.removeItem(CLE);
  } catch {
    /* rien */
  }
}

// Jeton d'identité valide (rafraîchi si besoin), ou null si non connecté
export async function jetonValide(): Promise<string | null> {
  const s = session.value;
  if (!s) return null;
  if (Date.now() < s.expire - 60_000) return s.idToken;
  try {
    const res = await cognito<Authentification>("InitiateAuth", {
      AuthFlow: "REFRESH_TOKEN_AUTH",
      AuthParameters: { REFRESH_TOKEN: s.refreshToken },
    });
    enregistrer(res.AuthenticationResult, s.refreshToken);
    return session.value!.idToken;
  } catch {
    deconnecter();
    return null;
  }
}
