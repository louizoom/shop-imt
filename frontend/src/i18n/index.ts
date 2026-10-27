import { createI18n } from "vue-i18n";
import en from "./en";
import fr, { type Messages } from "./fr";

export type Langue = "fr" | "en";
export const LANGUES: Langue[] = ["fr", "en"];
const CLE = "shopimt-langue";

const lireCookie = (nom: string) =>
  document.cookie
    .split("; ")
    .find((c) => c.startsWith(`${nom}=`))
    ?.split("=")[1];

// Ordre de priorité : choix fait sur le site, cookie « lang » posé par la CloudFront Function
// (d'après Accept-Language), langue du navigateur, français par défaut.
export function langueInitiale(): Langue {
  let choix: string | null | undefined = null;
  try {
    choix = localStorage.getItem(CLE);
  } catch {
    /* navigation privée */
  }
  choix ??= lireCookie("lang") ?? navigator.language?.slice(0, 2);
  return choix === "en" ? "en" : "fr";
}

export const i18n = createI18n<[Messages], Langue, false>({
  legacy: false,
  locale: langueInitiale(),
  fallbackLocale: "fr",
  messages: { fr, en },
});

export function changerLangue(langue: Langue) {
  i18n.global.locale.value = langue;
  document.documentElement.lang = langue;
  try {
    localStorage.setItem(CLE, langue);
  } catch {
    /* navigation privée */
  }
  document.cookie = `lang=${langue}; Path=/; Max-Age=31536000; SameSite=Lax; Secure`;
}
