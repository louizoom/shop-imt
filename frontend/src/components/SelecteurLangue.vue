<script setup lang="ts">
import { useI18n } from "vue-i18n";
import { changerLangue, LANGUES } from "@/i18n";

const { t, locale } = useI18n();
</script>

<template>
  <div class="langue" role="group" :aria-label="t('nav.langue')">
    <button v-for="l in LANGUES" :key="l" type="button" :aria-pressed="locale === l" :lang="l" @click="changerLangue(l)">
      {{ l.toUpperCase() }}
    </button>
  </div>
</template>
