"""Point d'entrée pytest : le parcours s'exécute dans l'ordre (création, publication, e-mails, admin…),
chaque étape réutilisant l'état laissé par la précédente, comme dans la vraie boutique."""
import os
import runpy


def test_parcours_complet():
    runpy.run_path(os.path.join(os.path.dirname(__file__), "parcours.py"), run_name="parcours")
