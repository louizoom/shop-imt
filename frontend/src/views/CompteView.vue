<script setup lang="ts">
import { nextTick, ref, watch } from "vue";
import { useI18n } from "vue-i18n";
import type { Langue } from "@/i18n";
import { appel, ErreurApi } from "@/lib/api";
import { dateHeure, euros, nomProduit } from "@/lib/format";
import { versSuivi } from "@/router";
import { cognito, connecter, deconnecter, ErreurCognito, session } from "@/lib/session";
import { image, type CommandeHistorique } from "@/lib/types";

// Comptes clients Amazon Cognito : connexion, inscription avec code, mot de passe oublié,
// puis historique des commandes (route /compte/commandes protégée par l'autorisateur JWT d'API Gateway).
type Etape = "connexion" | "inscription" | "code" | "reset";

const { t, te, locale } = useI18n();
const langue = () => locale.value as Langue;

const etape = ref<Etape>("connexion");
const email = ref("");
const motDePasse = ref("");
const code = ref("");
const nouveauMdp = ref("");
const message = ref("");
const erreur = ref(false);
const champCode = ref<HTMLInputElement | null>(null);
const champEmail = ref<HTMLInputElement | null>(null);

const commandes = ref<CommandeHistorique[] | null>(null);
const erreurHistorique = ref(false);

function informer(texte: string, estErreur = false) {
  message.value = texte;
  erreur.value = estErreur;
}

function messageErreur(e: unknown) {
  const cle = e instanceof ErreurCognito ? `cognito.${e.code}` : "";
  return cle && te(cle) ? t(cle) : t("cognito.defaut");
}

function choisir(nouvelle: Etape) {
  etape.value = nouvelle;
  informer("");
  if (nouvelle === "code" || nouvelle === "reset") nextTick(() => champCode.value?.focus());
}

async function soumettre() {
  const adresse = email.value.trim().toLowerCase();
  const inscription = etape.value === "inscription";
  informer(inscription ? t("compte.creation") : t("compte.connexionEnCours"));
  try {
    if (inscription) {
      await cognito("SignUp", { Username: adresse, Password: motDePasse.value, UserAttributes: [{ Name: "email", Value: adresse }] });
      email.value = adresse;
      choisir("code");
      return;
    }
    await connecter(adresse, motDePasse.value);
    motDePasse.value = "";
    informer("");
  } catch (e) {
    informer(messageErreur(e), true);
    if (e instanceof ErreurCognito && e.code === "UserNotConfirmedException") {
      email.value = adresse;
      etape.value = "code";
    }
  }
}

async function confirmer() {
  try {
    await cognito("ConfirmSignUp", { Username: email.value, ConfirmationCode: code.value.trim() });
    code.value = "";
    if (motDePasse.value) {
      // connexion directe après confirmation
      await connecter(email.value, motDePasse.value);
      motDePasse.value = "";
      etape.value = "connexion";
    } else {
      choisir("connexion");
      informer(t("compte.confirme"));
    }
  } catch (e) {
    informer(messageErreur(e), true);
  }
}

async function renvoyer() {
  try {
    await cognito("ResendConfirmationCode", { Username: email.value });
    informer(t("compte.codeRenvoye"));
  } catch (e) {
    informer(messageErreur(e), true);
  }
}

// Mot de passe oublié : Cognito envoie un code à l'adresse vérifiée (account_recovery_setting)
async function demanderReset() {
  const champ = champEmail.value;
  const adresse = email.value.trim().toLowerCase();
  if (!adresse || (champ && !champ.checkValidity())) {
    informer(t("compte.saisirEmail"), true);
    champ?.focus();
    return;
  }
  informer(t("compte.envoiCode"));
  try {
    await cognito("ForgotPassword", { Username: adresse });
    email.value = adresse;
    choisir("reset");
  } catch (e) {
    informer(messageErreur(e), true);
  }
}

async function reinitialiser() {
  informer(t("compte.changement"));
  try {
    await cognito("ConfirmForgotPassword", { Username: email.value, ConfirmationCode: code.value.trim(), Password: nouveauMdp.value });
    await connecter(email.value, nouveauMdp.value);
    code.value = nouveauMdp.value = "";
    choisir("connexion");
  } catch (e) {
    informer(messageErreur(e), true);
  }
}

async function chargerHistorique() {
  commandes.value = null;
  erreurHistorique.value = false;
  try {
    commandes.value = (await appel<{ commandes?: CommandeHistorique[] }>("/compte/commandes", { jeton: true })).commandes ?? [];
  } catch (e) {
    if (!(e instanceof ErreurApi && e.statut === 401)) erreurHistorique.value = true;
  }
}

const classeEtat = (s: string) => (s === "LIVREE" ? "etat ok" : s === "INCIDENT_TRANSPORT" ? "etat alerte" : "etat");

watch(
  () => session.value?.email,
  (connecte) => {
    if (connecte) chargerHistorique();
  },
  { immediate: true },
);
</script>

<template>
  <div class="compte">
    <div v-if="!session" id="compte-anonyme" class="fiche">
      <div v-if="etape === 'connexion' || etape === 'inscription'" class="onglets" role="tablist">
        <button type="button" role="tab" :aria-selected="etape === 'connexion'" @click="choisir('connexion')">
          {{ t("compte.connexion") }}
        </button>
        <button type="button" role="tab" :aria-selected="etape === 'inscription'" @click="choisir('inscription')">
          {{ t("compte.inscription") }}
        </button>
      </div>

      <form v-if="etape === 'connexion' || etape === 'inscription'" @submit.prevent="soumettre">
        <label for="compte-email">{{ t("compte.email") }}</label>
        <input id="compte-email" ref="champEmail" v-model="email" type="email" autocomplete="email" required />
        <label for="compte-mdp">{{ t("compte.motDePasse") }}</label>
        <input
          id="compte-mdp"
          v-model="motDePasse"
          type="password"
          minlength="8"
          required
          :autocomplete="etape === 'inscription' ? 'new-password' : 'current-password'"
        />
        <p v-if="etape === 'inscription'" class="aide">{{ t("compte.regleMdp") }}</p>
        <button class="principal">{{ etape === "inscription" ? t("compte.creer") : t("compte.connexion") }}</button>
        <button v-if="etape === 'connexion'" type="button" class="lien" @click="demanderReset">{{ t("compte.oublie") }}</button>
      </form>

      <form v-else-if="etape === 'reset'" @submit.prevent="reinitialiser">
        <p class="aide">
          {{ t("compte.codeReset") }} <b>{{ email }}</b
          >.
        </p>
        <label for="reset-code">{{ t("compte.code") }}</label>
        <input id="reset-code" ref="champCode" v-model="code" type="text" inputmode="numeric" autocomplete="one-time-code" required />
        <label for="reset-mdp">{{ t("compte.nouveauMdp") }}</label>
        <input id="reset-mdp" v-model="nouveauMdp" type="password" autocomplete="new-password" minlength="8" required />
        <p class="aide">{{ t("compte.regleMdp") }}</p>
        <button class="principal">{{ t("compte.changerMdp") }}</button>
        <button type="button" class="lien" @click="choisir('connexion')">{{ t("compte.retour") }}</button>
      </form>

      <form v-else @submit.prevent="confirmer">
        <p class="aide">
          {{ t("compte.codeConfirmation") }} <b>{{ email }}</b
          >.
        </p>
        <label for="compte-code">{{ t("compte.code") }}</label>
        <input id="compte-code" ref="champCode" v-model="code" type="text" inputmode="numeric" autocomplete="one-time-code" required />
        <button class="principal">{{ t("compte.confirmer") }}</button>
        <button type="button" class="lien" @click="renvoyer">{{ t("compte.renvoyer") }}</button>
      </form>

      <div class="message" :class="{ erreur }" aria-live="polite">{{ message }}</div>
      <p class="aide service">{{ t("compte.service") }}</p>
    </div>

    <div v-else id="compte-connecte">
      <div class="entete-compte">
        <div>
          <h2>{{ t("compte.mesCommandes") }}</h2>
          <p class="aide">{{ t("compte.connecteEn", { email: session.email }) }}</p>
        </div>
        <div class="actions">
          <button type="button" class="lien" @click="chargerHistorique">{{ t("compte.actualiser") }}</button>
          <button type="button" class="lien" @click="deconnecter">{{ t("compte.deconnexion") }}</button>
        </div>
      </div>
      <div id="historique" aria-live="polite">
        <template v-if="erreurHistorique">{{ t("compte.erreurHistorique") }}</template>
        <template v-else-if="commandes === null">{{ t("compte.chargement") }}</template>
        <div v-else-if="!commandes.length" class="vide-historique">
          {{ t("compte.aucune") }}
          <RouterLink class="lien" to="/">{{ t("compte.decouvrir") }}</RouterLink>
        </div>
        <button v-for="c in commandes" v-else :key="c.order_id" type="button" class="cmd" @click="versSuivi(c.order_id)">
          <div class="vignettes">
            <img v-for="a in c.articles.slice(0, 3)" :key="a.id" :src="image(a.id)" :alt="nomProduit(a, langue())" />
          </div>
          <div>
            <div class="quand">{{ dateHeure(c.cree_le, langue()) }}</div>
            <div class="detail">
              {{ t("compte.articles", c.nb_articles) }}<template v-if="c.transporteur"> · {{ c.transporteur }}</template>
            </div>
          </div>
          <div class="droite">
            <strong>{{ euros(c.total, langue()) }}</strong>
            <span :class="classeEtat(c.statut)">{{ t(`statuts.${c.statut}`) }}</span>
          </div>
        </button>
      </div>
    </div>
  </div>
</template>
