// Claro, escuro ou automático (segue o aparelho). Carrega antes do CSS para a
// tela não piscar. A escolha fica em Ajustes e vale só neste aparelho.
(function () {
  const escuro = window.matchMedia("(prefers-color-scheme: dark)");
  function escolha() {
    try {
      return localStorage.getItem("consultorio.tema") || "automatico";
    } catch (_) {
      return "automatico";
    }
  }
  function aplicar() {
    const e = escolha();
    const tema = e === "automatico" ? (escuro.matches ? "escuro" : "claro") : e;
    document.documentElement.setAttribute("data-tema", tema);
    const cor = document.querySelector('meta[name="theme-color"]');
    if (cor) cor.setAttribute("content", tema === "escuro" ? "#1b2621" : "#2C4A3E");
  }
  aplicar();
  if (escuro.addEventListener) escuro.addEventListener("change", aplicar);
  window.temaDoSite = {
    escolha: escolha,
    trocar: function (e) {
      try {
        if (e === "automatico") localStorage.removeItem("consultorio.tema");
        else localStorage.setItem("consultorio.tema", e);
      } catch (_) { /* sem armazenamento: vale até fechar */ }
      aplicar();
    },
  };
})();
