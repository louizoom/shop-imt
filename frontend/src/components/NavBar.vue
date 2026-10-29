<script setup lang="ts">
import { useI18n } from "vue-i18n";
import { useRoute } from "vue-router";
import SelecteurLangue from "@/components/SelecteurLangue.vue";
import { nbArticles } from "@/lib/boutique";
import { accesGestion, comptesActifs, estAdmin, peutGererStock, session } from "@/lib/session";

defineProps<{ modeAdmin: boolean }>();
const { t } = useI18n();
const route = useRoute();
const actif = (nom: string) => route.name === nom;
</script>

<template>
  <header>
    <div class="barre">
      <RouterLink class="logo" to="/">
        <img :src="modeAdmin ? '/img/logo-admin.svg' : '/img/logo.svg'" alt="SHOP'IMT" width="163" height="40" />
      </RouterLink>
      <a class="ecole" href="https://imt-nord-europe.fr/" target="_blank" rel="noopener">
        <img src="/img/logo-imt-nord-europe.png" alt="IMT Nord Europe" width="103" height="44" />
      </a>
      <nav>
        <RouterLink to="/" :class="{ actif: actif('boutique') }">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M8.5 8V6.5a3.5 3.5 0 0 1 7 0V8" />
            <path d="M4.5 8h15l-1.2 11.2a2 2 0 0 1-2 1.8H7.7a2 2 0 0 1-2-1.8z" /></svg
          >{{ t("nav.boutique") }}
          <span v-show="nbArticles > 0" id="nb-articles" class="badge">{{ nbArticles }}</span>
        </RouterLink>
        <RouterLink to="/suivi" :class="{ actif: actif('suivi') }">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M2.5 6.5h11v10h-11z" />
            <path d="M13.5 10h4l3 3v3.5h-7" />
            <circle cx="7" cy="17.5" r="1.8" />
            <circle cx="17" cy="17.5" r="1.8" /></svg
          >{{ t("nav.suivre") }}<span class="court-long">{{ t("nav.suivreLong") }}</span>
        </RouterLink>
        <RouterLink v-if="comptesActifs" to="/compte" :class="{ actif: actif('compte') }">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true">
            <circle cx="12" cy="8.5" r="4" />
            <path d="M4 20.5c1.2-3.6 4.3-5.5 8-5.5s6.8 1.9 8 5.5" /></svg
          >{{ session ? t("nav.mesCommandes") : t("nav.compte") }}
        </RouterLink>
        <RouterLink v-if="accesGestion" to="/admin" :class="{ actif: actif('admin') }">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path
              d="M12 21c-4 0-7-2.7-7-6.6 0-3.2 2.1-5.3 3.6-7.4.3 1.6 1.1 2.7 2.3 3.2C10.4 6.6 11.8 4 14.6 2.5c-.3 2.9.8 4.6 2.2 6.3 1.3 1.6 2.2 3.3 2.2 5.6 0 3.9-3 6.6-7 6.6z"
            />
            <path
              d="M12 21c-1.7 0-3-1.2-3-2.9 0-1.6 1.2-2.6 2-3.8.6 1 1.3 1.4 2 1.6.3-1 .2-2 0-2.9 1.3.9 2 2.4 2 4.1 0 2.1-1.3 3.9-3 3.9z"
            /></svg
          >{{ estAdmin ? t("nav.admin") : peutGererStock ? t("nav.stock") : t("nav.ventes") }}
        </RouterLink>
      </nav>
      <SelecteurLangue />
    </div>
  </header>
</template>
