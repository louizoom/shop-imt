// CloudFront Function (viewer-request) : routage du front (Vue Router, historique HTML5).
// Une adresse sans extension (/suivi/<id>, /compte, /admin) est servie par index.html, le routeur
// du navigateur affiche ensuite la bonne page. Les fichiers (/assets/x.js, /img/p001.jpg) passent tels quels.
// Les routes de l'API (/produits, /commandes*, /compte/*, /admin/*) ont leurs propres comportements :
// cette fonction ne les voit jamais.
function handler(event) {
  var request = event.request;
  var dernier = request.uri.split('/').pop();
  if (dernier.indexOf('.') === -1) {
    request.uri = '/index.html';
  }
  return request;
}
