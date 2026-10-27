<script setup lang="ts">
import { computed, onMounted, watchEffect } from "vue";
import { useRoute } from "vue-router";
import NavBar from "@/components/NavBar.vue";
import { chargerConfig } from "@/lib/session";

const route = useRoute();
const modeAdmin = computed(() => route.name === "admin");

// Console admin : thème sombre et rouge, y compris la barre du navigateur sur téléphone
watchEffect(() => {
  document.body.classList.toggle("mode-admin", modeAdmin.value);
  document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach((m) => {
    m.dataset.origine ??= m.content;
    m.content = modeAdmin.value ? "#090405" : m.dataset.origine;
  });
});

onMounted(chargerConfig);
</script>

<template>
  <NavBar :mode-admin="modeAdmin" />
  <main>
    <RouterView />
  </main>
</template>
